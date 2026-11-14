//
//  Tab.swift
//  dino
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import WebKit
import Combine
import UniformTypeIdentifiers

/// Lightweight console message entry captured from the page.
struct ConsoleEntry: Identifiable, Sendable {
    let id: UUID
    let level: Level
    let message: String
    let timestamp: Date

    enum Level: String, Codable, Sendable {
        case log
        case info
        case warn
        case error
    }

    init(id: UUID = UUID(), level: Level, message: String, timestamp: Date = Date()) {
        self.id = id
        self.level = level
        self.message = message
        self.timestamp = timestamp
    }
}

/// Metadata describing an inspected live DOM node in the page.
struct InspectedElementInfo: Sendable {
    let selector: String
    let tag: String
    let idAttr: String
    let classes: String
    let text: String
    let width: Int
    let height: Int
    let agentId: String?
}

/// Network request telemetry captured from client fetch / XHR.
struct NetworkEntry: Identifiable, Sendable {
    let id: UUID
    let method: String
    let url: String
    let status: Int
    let durationMs: Int
    let timestamp: Date
    let type: String
    let error: String?

    var isError: Bool { status >= 400 || status == 0 }

    init(id: UUID = UUID(), method: String, url: String, status: Int, durationMs: Int, timestamp: Date = Date(), type: String = "fetch", error: String? = nil) {
        self.id = id
        self.method = method
        self.url = url
        self.status = status
        self.durationMs = durationMs
        self.timestamp = timestamp
        self.type = type
        self.error = error
    }
}

/// Lifecycle execution tier for tabs under the memory governor.
enum TabTier: String, Codable, Sendable {
    case hot   // Active or recently focused tab: full GPU compositing, unrestricted timers
    case warm  // Inactive background tab: retained in memory, background timers active
    case cold  // Virtualized/suspended tab: webView unloaded, state preserved on disk/memory
}

/// Represents an individual browser tab.
/// Owns its WKWebView instance so switching tabs is instant and preserves scroll state.
@MainActor
final class Tab: NSObject, Identifiable, ObservableObject {
    let id: UUID
    
    @Published var url: URL?
    @Published var title: String
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isBlank: Bool = true
    @Published var favicon: NSImage? = nil
    @Published var isIncognito: Bool = false
    @Published var tier: TabTier = .hot
    var lastActiveTime: Date = Date()

    // MARK: - Navigation History Stacks
    private var historyBackStack: [URL?] = []
    private var historyForwardStack: [URL?] = []

    func updateNavigationState() {
        let backAvailable: Bool = {
            if isInternalPage {
                return !historyBackStack.isEmpty
            }
            return webView.canGoBack || !historyBackStack.isEmpty
        }()
        let forwardAvailable: Bool = {
            if isInternalPage {
                return !historyForwardStack.isEmpty
            }
            return webView.canGoForward || !historyForwardStack.isEmpty
        }()
        if self.canGoBack != backAvailable {
            self.canGoBack = backAvailable
        }
        if self.canGoForward != forwardAvailable {
            self.canGoForward = forwardAvailable
        }
    }

    // MARK: - Developer Drawer & Live Inspection State
    @Published var isDevDrawerVisible: Bool = false
    @Published var isInspectorActive: Bool = false
    @Published var isZapperActive: Bool = false
    @Published var isReaderModeActive: Bool = false
    @Published var isShowingOfflinePage: Bool = false
    @Published var isFloatingVideo: Bool = false
    @Published var wantsNextNewTabInSplit: Bool = false
    // MARK: - Phase 1: Tab Lifecycle, Grouping & Basecamp
    public enum TabPlace: String, Codable, Sendable {
        case basecamp, open, drifted
    }

    @Published var place: TabPlace = .open
    @Published var homeURL: URL? = nil
    @Published var groupId: UUID? = nil
    @Published var driftedAt: Date? = nil
    @Published var faviconPNGData: Data? = nil

    var isAwayFromHome: Bool {
        guard place == .basecamp, let home = homeURL, let current = url else { return false }
        return home != current
    }

    func goHome() {
        guard let target = homeURL ?? url else { return }
        load(url: target)
    }

    var siteColors: IconColor.Colors? {
        guard let data = faviconPNGData else { return nil }
        return IconColor.from(png: data)
    }

    @Published var wantsNextNewTabIncognito: Bool = false
    @Published var isPinned: Bool = false
    @Published var isGhost: Bool = false
    @Published var isHitlActive: Bool = false
    @Published var hitlChallengeType: String? = nil
    @Published var spaceId: UUID? = nil
    @Published var profileType: DinoProfileType = DinoProfileManager.defaultProfile
    @Published var hoveredLink: String? = nil
    @Published var readerArticle: ReaderArticle? = nil
    @Published var consoleEntries: [ConsoleEntry] = []
    @Published var networkEntries: [NetworkEntry] = []
    @Published var inspectedElementInfo: InspectedElementInfo? = nil

    /// Detects if this tab is on a Chrome Web Store extension detail page and extracts the 32-letter ID.
    var chromeWebStoreExtensionId: String? {
        guard let url = url,
              let host = url.host,
              host.contains("chromewebstore.google.com") || host.contains("chrome.google.com"),
              url.path.contains("/detail/") else {
            return nil
        }
        return CrxDownloader.extractID(from: url.absoluteString)
    }

    /// Clean display title for the extension detected on this tab.
    var chromeWebStoreExtensionName: String? {
        guard chromeWebStoreExtensionId != nil else { return nil }
        if !title.isEmpty && title != "Chrome Web Store" {
            let clean = title.replacingOccurrences(of: " - Chrome Web Store", with: "")
                             .replacingOccurrences(of: " - Chrome web store", with: "")
            if !clean.isEmpty { return clean }
        }
        if let pathComponents = url?.pathComponents, pathComponents.count >= 3 {
            let slug = pathComponents[pathComponents.count - 2]
            if slug != "detail" {
                return slug.replacingOccurrences(of: "-", with: " ").capitalized
            }
        }
        return "Extension"
    }

    // MARK: - Fluid Two-Finger Swipe Navigation State
    enum SwipeDirection {
        case back
        case forward
    }

    struct SwipeGestureState {
        var direction: SwipeDirection
        var progress: CGFloat
        var distance: CGFloat
        var isTriggered: Bool
    }

    enum PendingDialogType: String {
        case alert
        case confirm
        case prompt
    }

    struct PendingDialog {
        let type: PendingDialogType
        let message: String
        let defaultText: String?
        let timestamp: Date
        let resolve: (Any?) -> Void
    }

    @Published var swipeState: SwipeGestureState? = nil
    @Published var lastNavigationError: String? = nil
    @Published var lastDialog: String? = nil
    @Published var dialogPolicy: String = "dismiss"
    @Published var dialogPromptResponse: String = ""
    var pendingDialog: PendingDialog? = nil
    var dialogTimeoutTask: Task<Void, Never>? = nil
    var onDialogAppeared: ((PendingDialog) -> Void)? = nil
    @Published var navigationSeq: Int = 0
    @Published var committedNavigationSeq: Int = 0
    @Published var lastFailedNavigationSeq: Int = 0
    @Published var lastNavigationStartTime: Date? = nil
    @Published var lastNavigationFinishTime: Date? = nil
    @Published var lastActionTime: Date? = nil
    var allowNextFileNavigation: Bool = false
    var currentNavigation: WKNavigation? = nil
    var blockedURLPatterns: [String] = []
    var mockRoutes: [[String: Any]] = []

    func syncMockRoutes() {
        guard !mockRoutes.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: mockRoutes),
              let json = String(data: data, encoding: .utf8) else {
            webView.evaluateJavaScript("window.__dino_mock_routes = [];", in: nil, in: .page, completionHandler: nil)
            webView.evaluateJavaScript("window.__dino_mock_routes = [];", in: nil, in: .defaultClient, completionHandler: nil)
            return
        }
        let js = "window.__dino_mock_routes = \(json);"
        webView.evaluateJavaScript(js, in: nil, in: .page, completionHandler: nil)
        webView.evaluateJavaScript(js, in: nil, in: .defaultClient, completionHandler: nil)
    }
    private var navigationSeqMap: [ObjectIdentifier: Int] = [:]

    func recordNavigation(_ navigation: WKNavigation?, for seq: Int) {
        guard let navigation = navigation else { return }
        navigationSeqMap[ObjectIdentifier(navigation)] = seq
    }

    func sequence(for navigation: WKNavigation?) -> Int? {
        guard let navigation = navigation else { return nil }
        return navigationSeqMap[ObjectIdentifier(navigation)]
    }

    /// Staged file URLs ready for programmatic consumption by runOpenPanelWith during agent file uploads.
    var stagedUploadURLs: [URL]? = nil
    var stagedUploadTimeoutTimer: Timer? = nil

    func stageUpload(urls: [URL]) {
        stagedUploadURLs = urls
        stagedUploadTimeoutTimer?.invalidate()
        stagedUploadTimeoutTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stagedUploadURLs = nil
            }
        }
    }

    func clearStagedUpload() {
        stagedUploadTimeoutTimer?.invalidate()
        stagedUploadTimeoutTimer = nil
        stagedUploadURLs = nil
    }
    
    /// The retained custom web view for this tab.
    private(set) var webView: BrowserWebView
    
    /// Optional hook called when web content requests opening a new window (e.g. target="_blank").
    var onOpenURLInNewTab: ((URL) -> Void)?

    /// Hook to create a full new tab and return its WKWebView when a page requests window.open / target="_blank"
    var onOpenTabWithWebView: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?

    /// Hook to close this tab if it was opened solely for an immediate file download
    var onRequestCloseTab: (() -> Void)?

    /// Hook to request opening a new tab
    var onRequestNewTab: ((URL?) -> Void)?

    /// Hook to request peeking at a link in a floating preview
    var onRequestPeek: ((URL) -> Void)?

    /// Hook to request duplicating this tab
    var onRequestDuplicateTab: (() -> Void)?

    /// Hook called when this tab receives user interaction / focus
    var onDidFocus: (() -> Void)?
    
    private(set) var hasLoaded: Bool = false
    private var observers: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), initialURL: URL? = nil, configuration: WKWebViewConfiguration? = nil, profileType: DinoProfileType? = nil, isIncognito: Bool = false, isGhost: Bool = false, lazy: Bool = false) {
        self.id = id
        self.url = initialURL
        self.isIncognito = isIncognito
        self.isGhost = isGhost
        let effectiveProfile = profileType ?? DinoProfileManager.defaultProfile
        self.profileType = effectiveProfile

        if let initialURL = initialURL,
           (initialURL.scheme == ExtensionManager.scheme || initialURL.scheme == "webkit-extension"),
           let host = initialURL.host,
           let ext = ExtensionManager.shared.installed.first(where: { $0.id == host }) {
            self.title = ext.name
        } else if isIncognito && (initialURL == nil || initialURL?.absoluteString == "about:blank") {
            self.title = "Private Tab"
        } else {
            self.title = initialURL?.host ?? "New Tab"
        }

        self.isBlank = (initialURL == nil || initialURL?.absoluteString == "about:blank")
        
        let effectiveConfig = configuration ?? ExtensionManager.shared.configuration(for: initialURL) ?? WebKitPool.makeConfiguration(profile: effectiveProfile, isIncognito: isIncognito)
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 730), configuration: effectiveConfig)
        webView.appearance = SettingsStore.shared.currentAppearance
        webView.customUserAgent = WebKitPool.customUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setMagnification(1.0, centeredAt: .zero)
        webView.pageZoom = 1.0
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        if #available(macOS 14.0, *) {
            webView.configuration.preferences.inactiveSchedulingPolicy = .none
        }
        self.webView = webView
        
        super.init()
        
        webView.tab = self
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        
        let ucc = effectiveConfig.userContentController
        ucc.removeScriptMessageHandler(forName: "dinoConsole")
        ucc.removeScriptMessageHandler(forName: "dinoInspect")
        ucc.removeScriptMessageHandler(forName: "dinoNetwork", contentWorld: .page)
        ucc.removeScriptMessageHandler(forName: "dinoNetwork", contentWorld: .defaultClient)
        ucc.removeScriptMessageHandler(forName: "dinoZapper")
        ucc.removeScriptMessageHandler(forName: "dinoFrameBridge")
        ucc.removeScriptMessageHandler(forName: "dinoLinkHover")
        ucc.removeScriptMessageHandler(forName: "dinoAutofill")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoConsole")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoInspect")
        ucc.add(WeakScriptMessageHandler(delegate: self), contentWorld: .page, name: "dinoNetwork")
        ucc.add(WeakScriptMessageHandler(delegate: self), contentWorld: .defaultClient, name: "dinoNetwork")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoZapper")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoFrameBridge")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoLinkHover")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "dinoAutofill")

        let linkScript = WKUserScript(
            source: TabScripts.linkHoverAndAutofillScript,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: false
        )
        ucc.addUserScript(linkScript)

        setupObservers()

        if DinoHeadlessManager.isHeadless {
            DinoHeadlessManager.shared.attachTabWebView(webView)
        }
        
        if let initialURL = initialURL {
            if lazy {
                self.hasLoaded = false
            } else {
                self.hasLoaded = true
                load(url: initialURL)
            }
        } else {
            self.hasLoaded = true
        }
    }

    /// Loads the URL if this tab was lazily preserved in the background on startup.
    func ensureLoaded() {
        guard !hasLoaded, let url = self.url, !isBlank, !isInternalPage else { return }
        hasLoaded = true
        load(url: url)
    }

    // MARK: - Tab Tier Virtualization (Hot / Warm / Cold)

    /// Suspends an idle background tab, releasing its GPU pipeline and WebContent memory.
    func dehydrateToCold() {
        guard tier != .cold, !isLoading, let _ = self.url, !isBlank, !isInternalPage else { return }
        tier = .cold
        _ = webView.load(URLRequest(url: URL(string: "about:blank")!))
    }

    /// Rehydrates a cold tab back into full GPU execution.
    func hydrateToHot() {
        lastActiveTime = Date()
        guard tier == .cold, let u = self.url, !isBlank, !isInternalPage else {
            tier = .hot
            return
        }
        tier = .hot
        load(url: u)
    }

    // MARK: - Swipe Gesture Coordinator
    func updateSwipeGesture(direction: SwipeDirection, progress: CGFloat, distance: CGFloat, isTriggered: Bool) {
        self.swipeState = SwipeGestureState(
            direction: direction,
            progress: progress,
            distance: distance,
            isTriggered: isTriggered
        )
    }

    func cancelSwipeGesture() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            self.swipeState = nil
        }
    }

    func finishSwipeGesture(commit: Bool, direction: SwipeDirection) {
        if commit {
            withAnimation(.easeOut(duration: 0.2)) {
                self.swipeState = nil
            }
            if direction == .back {
                self.goBack()
            } else {
                self.goForward()
            }
        } else {
            cancelSwipeGesture()
        }
    }

    /// Tear down observers and script handlers when tab is explicitly closed
    func cleanup() {
        FloatingVideoManager.shared.landIfTab(id: id)
        observers.forEach { $0.invalidate() }
        observers.removeAll()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoConsole")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoInspect")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoNetwork", contentWorld: .page)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoNetwork", contentWorld: .defaultClient)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoZapper")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoFrameBridge")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoLinkHover")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "dinoAutofill")
    }

    deinit {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
    }

    var isInternalPage: Bool {
        url?.scheme == "dino"
    }

    /// Loads a user-typed string (resolved via URLParser).
    func load(text: String) {
        let destination = URLParser.parse(text)
        load(url: destination)
    }

    /// Loads a specific URL.
    func load(url: URL) {
        self.navigationSeq += 1
        let seq = self.navigationSeq
        self.lastNavigationStartTime = Date()
        self.lastNavigationError = nil

        let prev = self.url
        if prev != url {
            if let p = prev {
                historyBackStack.append(p)
            } else if !isBlank {
                historyBackStack.append(nil)
            }
            historyForwardStack.removeAll()
        }

        self.url = url
        if url.scheme == "dino" {
            self.isBlank = false
            self.isLoading = false
            self.title = "Settings"
            updateNavigationState()
            return
        }

        if url.scheme == ExtensionManager.scheme || url.scheme == "webkit-extension" {
            if let host = url.host, let ext = ExtensionManager.shared.installed.first(where: { $0.id == host }) {
                self.title = ext.name
            }
            ensureConfiguration(for: url)
        }

        self.isBlank = (url.absoluteString == "about:blank")
        self.favicon = nil
        self.lastDialog = nil
        if let pending = self.pendingDialog {
            self.pendingDialog = nil
            self.dialogTimeoutTask?.cancel()
            self.dialogTimeoutTask = nil
            pending.resolve(nil)
        }
        webView.setMagnification(1.0, centeredAt: .zero)
        if webView.isLoading {
            webView.stopLoading()
        }
        if url.isFileURL {
            self.allowNextFileNavigation = true
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
            let ext = resolved.pathExtension.lowercased()
            let isWebDocument = ["html", "htm", "xhtml", "svg", "pdf"].contains(ext)
            let readDir = resolved.pathComponents.count > 2 ? resolved.deletingLastPathComponent() : URL(fileURLWithPath: "/")
            self.url = resolved
            if isWebDocument {
                self.currentNavigation = webView.loadFileURL(resolved, allowingReadAccessTo: readDir)
            } else {
                if let data = try? Data(contentsOf: resolved) {
                    let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
                    self.currentNavigation = webView.load(data, mimeType: mimeType, characterEncodingName: "utf-8", baseURL: resolved)
                } else {
                    self.currentNavigation = webView.loadFileURL(resolved, allowingReadAccessTo: readDir)
                }
            }
        } else {
            let request = URLRequest(url: url)
            self.currentNavigation = webView.load(request)
        }
        recordNavigation(self.currentNavigation, for: seq)
        fetchFavicon(for: url)
        updateNavigationState()
    }

    /// Dynamically switches the web view configuration if navigating to an extension that requires WKWebExtensionContext.webViewConfiguration.
    func ensureConfiguration(for targetURL: URL) {
        guard (targetURL.scheme == ExtensionManager.scheme || targetURL.scheme == "webkit-extension"),
              let host = targetURL.host,
              let targetConfig = ExtensionManager.shared.contexts[host]?.webViewConfiguration,
              webView.configuration !== targetConfig else {
            return
        }

        observers.forEach { $0.invalidate() }
        observers.removeAll()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.tab = nil

        let newWebView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 730), configuration: targetConfig)
        newWebView.appearance = SettingsStore.shared.currentAppearance
        newWebView.customUserAgent = WebKitPool.customUserAgent
        newWebView.allowsBackForwardNavigationGestures = false
        newWebView.allowsMagnification = false
        newWebView.setMagnification(1.0, centeredAt: .zero)
        newWebView.pageZoom = 1.0
        newWebView.tab = self
        newWebView.navigationDelegate = self
        newWebView.uiDelegate = self
        self.webView = newWebView
        setupObservers()

        if DinoHeadlessManager.isHeadless {
            DinoHeadlessManager.shared.attachTabWebView(webView)
        }
    }

    func goBack() {
        if isInternalPage {
            if let prev = historyBackStack.popLast() {
                if let cur = self.url {
                    historyForwardStack.append(cur)
                }
                if let target = prev {
                    if target.scheme == "dino" {
                        self.url = target
                        self.isBlank = false
                        self.title = "Settings"
                    } else {
                        self.url = target
                        self.isBlank = (target.absoluteString == "about:blank")
                        if webView.url == target {
                            self.title = webView.title ?? target.host ?? "New Tab"
                        } else {
                            let request = URLRequest(url: target)
                            self.currentNavigation = webView.load(request)
                        }
                    }
                } else {
                    self.url = nil
                    self.isBlank = true
                    self.title = "New Tab"
                }
                updateNavigationState()
                return
            }
        }

        if webView.canGoBack {
            webView.goBack()
            updateNavigationState()
            return
        }

        if let prev = historyBackStack.popLast() {
            if let cur = self.url {
                historyForwardStack.append(cur)
            }
            if let target = prev {
                if target.scheme == "dino" {
                    self.url = target
                    self.isBlank = false
                    self.title = "Settings"
                } else {
                    load(url: target)
                }
            } else {
                self.url = nil
                self.isBlank = true
                self.title = "New Tab"
            }
            updateNavigationState()
        }
    }

    func goForward() {
        if isInternalPage {
            if let next = historyForwardStack.popLast() {
                if let cur = self.url {
                    historyBackStack.append(cur)
                }
                if let target = next {
                    if target.scheme == "dino" {
                        self.url = target
                        self.isBlank = false
                        self.title = "Settings"
                    } else {
                        self.url = target
                        self.isBlank = (target.absoluteString == "about:blank")
                        if webView.url == target {
                            self.title = webView.title ?? target.host ?? "New Tab"
                        } else {
                            let request = URLRequest(url: target)
                            self.currentNavigation = webView.load(request)
                        }
                    }
                } else {
                    self.url = nil
                    self.isBlank = true
                    self.title = "New Tab"
                }
                updateNavigationState()
                return
            }
        }

        if webView.canGoForward {
            webView.goForward()
            updateNavigationState()
            return
        }

        if let next = historyForwardStack.popLast() {
            if let cur = self.url {
                historyBackStack.append(cur)
            }
            if let target = next {
                if target.scheme == "dino" {
                    self.url = target
                    self.isBlank = false
                    self.title = "Settings"
                } else {
                    load(url: target)
                }
            } else {
                self.url = nil
                self.isBlank = true
                self.title = "New Tab"
            }
            updateNavigationState()
        }
    }

    func reload() {
        if isInternalPage { return }
        self.currentNavigation = webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    // MARK: - Browser Page Zoom (Standards-compliant HTML reflow zoom: ⌘+, ⌘-, ⌘0)
    var currentZoom: Double {
        webView.pageZoom
    }

    func zoomIn() {
        guard !isInternalPage else { return }
        let next = min(webView.pageZoom + 0.1, 3.0)
        webView.pageZoom = (next * 10).rounded() / 10.0
    }

    func zoomOut() {
        guard !isInternalPage else { return }
        let next = max(webView.pageZoom - 0.1, 0.5)
        webView.pageZoom = (next * 10).rounded() / 10.0
    }

    func resetZoom() {
        guard !isInternalPage else { return }
        webView.pageZoom = 1.0
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
    }

    // MARK: - Find in Page (⌘F)
    @Published var isFindBarVisible: Bool = false
    @Published var findQuery: String = ""
    @Published var findHasMatches: Bool = false
    @Published var findCount: Int? = nil

    func findInPage(_ query: String, forward: Bool = true) {
        let cleanQuery = FindOnPage.query(query)
        self.findQuery = cleanQuery
        guard !cleanQuery.isEmpty else {
            clearFind()
            return
        }

        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true

        webView.find(cleanQuery, configuration: config) { [weak self] result in
            Task { @MainActor in
                self?.findHasMatches = result.matchFound
            }
        }

        // Count occurrences
        let js = "\(FindOnPage.countScript)(\(cleanQuery.debugDescription), \(FindOnPage.countLimit));"
        webView.evaluateJavaScript(js) { [weak self] val, _ in
            Task { @MainActor in
                if let num = val as? NSNumber {
                    self?.findCount = min(max(num.intValue, 1), FindOnPage.countLimit)
                } else {
                    self?.findCount = nil
                }
            }
        }
    }

    func clearFind() {
        findQuery = ""
        findHasMatches = false
        findCount = nil
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
    }

    func closeFind() {
        isFindBarVisible = false
        clearFind()
    }

    // MARK: - Media & Sound Playback
    @Published var isPlayingAudio: Bool = false
    @Published var isAudioPausedByPlayer: Bool = false

    func toggleMediaPlayback() {
        isAudioPausedByPlayer.toggle()
        let shouldPause = isAudioPausedByPlayer
        let js = """
        (function() {
            const media = document.querySelectorAll('audio, video');
            for (const el of media) {
                if (\(shouldPause)) {
                    el.pause();
                } else {
                    var p = el.play();
                    if (p) p.catch(function() {});
                }
            }
        })();
        """
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    func checkMediaPlayback() {
        guard !isBlank, !isInternalPage else { return }
        let js = "Boolean(Array.from(document.querySelectorAll('audio, video')).find(el => !el.paused && !el.ended))"
        webView.evaluateJavaScript(js) { [weak self] val, _ in
            Task { @MainActor in
                if let playing = val as? Bool {
                    self?.isPlayingAudio = playing
                }
            }
        }
    }

    // MARK: - Native Print & PDF Export (⌘P)
    func printPage() {
        guard !isInternalPage else { return }
        let printInfo = NSPrintInfo.shared
        printInfo.orientation = .portrait
        printInfo.horizontalPagination = .automatic
        printInfo.verticalPagination = .automatic

        let printOperation = webView.printOperation(with: printInfo)
        if let window = webView.window {
            printOperation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            printOperation.run()
        }
    }

    // MARK: - Developer Drawer & Live Inspection
    func appendConsoleEntry(level: ConsoleEntry.Level, message: String) {
        let entry = ConsoleEntry(level: level, message: message)
        if consoleEntries.count > 600 {
            consoleEntries.removeFirst(100)
        }
        consoleEntries.append(entry)
    }

    func startElementInspector() {
        guard !isInternalPage && !isBlank else { return }
        isInspectorActive = true
        webView.evaluateJavaScript(TabScripts.startInspector, completionHandler: nil)
    }

    func highlightInspectedElement() {
        guard let selector = inspectedElementInfo?.selector, !selector.isEmpty else { return }
        webView.evaluateJavaScript(TabScripts.highlightElement(selector: selector), completionHandler: nil)
    }

    // MARK: - Element Zapper (Hide Anything ⇧⌘H)
    func toggleElementZapper() {
        guard !isInternalPage && !isBlank else { return }
        if isZapperActive {
            stopElementZapper()
        } else {
            startElementZapper()
        }
    }

    func startElementZapper() {
        guard !isInternalPage && !isBlank else { return }
        isZapperActive = true
        NSCursor.crosshair.set()
        webView.evaluateJavaScript(TabScripts.startZapper, completionHandler: nil)
    }

    func stopElementZapper() {
        isZapperActive = false
        objectWillChange.send()
        NSCursor.arrow.set()
        webView.evaluateJavaScript(TabScripts.stopZapper, completionHandler: nil)
    }

    /// Clears all zapped selectors for current host and restores hidden elements on the page immediately
    func unhideAllZappedElements() {
        guard let host = url?.host ?? webView.url?.host else { return }
        ZapperStore.shared.clearSelectors(for: host)
        webView.evaluateJavaScript("document.getElementById('dino-zapped-rules')?.remove()", completionHandler: nil)
    }

    // MARK: - Reading Mode (⇧⌘R)
    func toggleReaderMode() {
        if isReaderModeActive {
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isReaderModeActive = false
                self.readerArticle = nil
            }
            return
        }
        guard !isInternalPage && !isBlank else { return }

        webView.evaluateJavaScript(TabScripts.extractReaderArticle) { [weak self] result, error in
            guard let self = self, let dict = result as? [String: Any] else { return }
            let title = dict["title"] as? String ?? self.title
            let byline = dict["byline"] as? String ?? ""
            let siteName = dict["siteName"] as? String ?? (self.url?.host ?? "")
            let paragraphs = dict["paragraphs"] as? [String] ?? []
            let wordCount = dict["wordCount"] as? Int ?? 0
            let readingTime = dict["readingTime"] as? Int ?? 1

            guard !paragraphs.isEmpty else { return }

            self.readerArticle = ReaderArticle(
                title: title,
                byline: byline,
                siteName: siteName,
                paragraphs: paragraphs,
                wordCount: wordCount,
                readingTimeMinutes: readingTime,
                url: self.url
            )
            withAnimation(.easeInOut(duration: 0.18)) {
                self.isReaderModeActive = true
            }
        }
    }

    // MARK: - Picture-in-Picture (Floating Video ⇧⌘P)
    func togglePictureInPicture() {
        FloatingVideoManager.shared.toggle(tab: self)
    }


    // MARK: - KVO Observers
    private func setupObservers() {
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let newTitle = wv.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor [weak self] in
                guard let self, !self.isInternalPage else { return }
                if !newTitle.isEmpty {
                    self.title = newTitle
                } else if let url = self.url ?? self.webView.url,
                          (url.scheme == ExtensionManager.scheme || url.scheme == "webkit-extension"),
                          let host = url.host,
                          let ext = ExtensionManager.shared.installed.first(where: { $0.id == host }) {
                    self.title = ext.name
                } else {
                    self.title = self.url?.host ?? "New Tab"
                }
                ExtensionManager.shared.tabDidChange(self, properties: [.title])
            }
        })

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let newURL = wv.url
            Task { @MainActor [weak self] in
                guard let self, !self.isInternalPage else { return }
                if let newURL = newURL {
                    self.url = newURL
                    self.isBlank = (newURL.absoluteString == "about:blank")
                    self.fetchFavicon(for: newURL)
                } else if self.url == nil {
                    self.isBlank = true
                }
                self.updateNavigationState()
                ExtensionManager.shared.tabDidChange(self, properties: [.URL])
            }
        })

        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let loading = wv.isLoading
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = loading
                if !loading {
                    self.lastNavigationFinishTime = Date()
                } else {
                    self.lastNavigationStartTime = Date()
                }
                ExtensionManager.shared.tabDidChange(self, properties: [.loading])
            }
        })

        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let progress = wv.estimatedProgress
            Task { @MainActor [weak self] in
                self?.estimatedProgress = progress
            }
        })

        observers.append(webView.observe(\.canGoBack, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self.updateNavigationState()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updateNavigationState()
                }
            }
        })

        observers.append(webView.observe(\.canGoForward, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            if Thread.isMainThread {
                MainActor.assumeIsolated {
                    self.updateNavigationState()
                }
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.updateNavigationState()
                }
            }
        })
    }

    // MARK: - Favicon Fetching
    func fetchFavicon(for url: URL) {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host, !host.isEmpty else {
            self.favicon = nil
            self.faviconPNGData = nil
            return
        }

        if let cached = FaviconService.shared.cachedFavicon(for: host) {
            self.favicon = cached
            if let tiff = cached.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                self.faviconPNGData = rep.representation(using: .png, properties: [:])
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let image = await FaviconService.shared.loadFavicon(for: url) {
                if self.url?.host == host || self.webView.url?.host == host {
                    self.favicon = image
                    if let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                        self.faviconPNGData = rep.representation(using: .png, properties: [:])
                    }
                }
            }
        }
    }
}
