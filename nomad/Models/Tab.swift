//
//  Tab.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import WebKit
import Combine

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

    // MARK: - Developer Drawer & Live Inspection State
    @Published var isDevDrawerVisible: Bool = false
    @Published var isInspectorActive: Bool = false
    @Published var isZapperActive: Bool = false
    @Published var isReaderModeActive: Bool = false
    @Published var isFloatingVideo: Bool = false
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

    @Published var swipeState: SwipeGestureState? = nil
    
    /// The retained custom web view for this tab.
    private(set) var webView: BrowserWebView
    
    /// Optional hook called when web content requests opening a new window (e.g. target="_blank").
    var onOpenURLInNewTab: ((URL) -> Void)?

    /// Hook to create a full new tab and return its WKWebView when a page requests window.open / target="_blank"
    var onOpenTabWithWebView: ((WKWebViewConfiguration, WKNavigationAction) -> WKWebView?)?

    /// Hook to close this tab if it was opened solely for an immediate file download
    var onRequestCloseTab: (() -> Void)?
    
    private(set) var hasLoaded: Bool = false
    private var observers: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), initialURL: URL? = nil, configuration: WKWebViewConfiguration? = nil, isIncognito: Bool = false, lazy: Bool = false) {
        self.id = id
        self.url = initialURL
        self.isIncognito = isIncognito

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
        
        let effectiveConfig = configuration ?? ExtensionManager.shared.configuration(for: initialURL) ?? WebKitPool.makeConfiguration(isIncognito: isIncognito)
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 730), configuration: effectiveConfig)
        webView.customUserAgent = WebKitPool.customUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setMagnification(1.0, centeredAt: .zero)
        webView.pageZoom = 1.0
        if #available(macOS 13.3, *) {
            webView.isInspectable = true
        }
        self.webView = webView
        
        super.init()
        
        webView.tab = self
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        
        let ucc = effectiveConfig.userContentController
        ucc.removeScriptMessageHandler(forName: "nomadConsole")
        ucc.removeScriptMessageHandler(forName: "nomadInspect")
        ucc.removeScriptMessageHandler(forName: "nomadNetwork")
        ucc.removeScriptMessageHandler(forName: "nomadZapper")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "nomadConsole")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "nomadInspect")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "nomadNetwork")
        ucc.add(WeakScriptMessageHandler(delegate: self), name: "nomadZapper")

        setupObservers()
        
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
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nomadConsole")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nomadInspect")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nomadNetwork")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "nomadZapper")
    }

    deinit {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
    }

    var isInternalPage: Bool {
        url?.scheme == "nomad"
    }

    /// Loads a user-typed string (resolved via URLParser).
    func load(text: String) {
        let destination = URLParser.parse(text)
        load(url: destination)
    }

    /// Loads a specific URL.
    func load(url: URL) {
        self.url = url
        if url.scheme == "nomad" {
            self.isBlank = false
            self.isLoading = false
            self.title = "Settings"
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
        webView.setMagnification(1.0, centeredAt: .zero)
        let request = URLRequest(url: url)
        webView.load(request)
        fetchFavicon(for: url)
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
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func reload() {
        if isInternalPage { return }
        webView.reload()
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

    func findInPage(_ query: String, forward: Bool = true) {
        self.findQuery = query
        guard !query.isEmpty else {
            clearFind()
            return
        }

        let config = WKFindConfiguration()
        config.backwards = !forward
        config.caseSensitive = false
        config.wraps = true

        webView.find(query, configuration: config) { [weak self] result in
            Task { @MainActor in
                self?.findHasMatches = result.matchFound
            }
        }
    }

    func clearFind() {
        findQuery = ""
        findHasMatches = false
        webView.evaluateJavaScript("window.getSelection().removeAllRanges()", completionHandler: nil)
    }

    func closeFind() {
        isFindBarVisible = false
        clearFind()
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
        let script = """
        (function() {
            if (window.__nomad_inspector_active) return;
            window.__nomad_inspector_active = true;
            let overlay = document.getElementById('__nomad_inspect_overlay');
            if (!overlay) {
                overlay = document.createElement('div');
                overlay.id = '__nomad_inspect_overlay';
                overlay.style.position = 'fixed';
                overlay.style.pointerEvents = 'none';
                overlay.style.border = '2px solid #007aff';
                overlay.style.backgroundColor = 'rgba(0, 122, 255, 0.15)';
                overlay.style.zIndex = '2147483647';
                overlay.style.transition = 'all 0.05s ease';
                overlay.style.borderRadius = '3px';
                document.body.appendChild(overlay);
            }
            overlay.style.display = 'none';

            function onMouseMove(e) {
                const el = document.elementFromPoint(e.clientX, e.clientY);
                if (!el || el === overlay) return;
                const rect = el.getBoundingClientRect();
                overlay.style.left = rect.left + 'px';
                overlay.style.top = rect.top + 'px';
                overlay.style.width = rect.width + 'px';
                overlay.style.height = rect.height + 'px';
                overlay.style.display = 'block';
            }

            function cleanup() {
                window.__nomad_inspector_active = false;
                document.removeEventListener('mousemove', onMouseMove, true);
                document.removeEventListener('click', onClick, true);
                document.removeEventListener('keydown', onKeyDown, true);
                if (overlay) overlay.style.display = 'none';
            }

            function onClick(e) {
                e.preventDefault();
                e.stopPropagation();
                const el = document.elementFromPoint(e.clientX, e.clientY);
                if (el && el !== overlay) {
                    const rect = el.getBoundingClientRect();
                    let sel = el.tagName.toLowerCase();
                    if (el.id) {
                        sel += '#' + el.id;
                    } else if (el.className && typeof el.className === 'string') {
                        const cls = el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
                        if (cls) sel += '.' + cls;
                    }
                    const info = {
                        selector: sel,
                        tag: el.tagName.toLowerCase(),
                        idAttr: el.id || '',
                        classes: typeof el.className === 'string' ? el.className.trim() : '',
                        text: (el.innerText || el.textContent || '').trim().slice(0, 300),
                        width: Math.round(rect.width),
                        height: Math.round(rect.height),
                        agentId: el.getAttribute('data-nomad-id') || null
                    };
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadInspect) {
                        window.webkit.messageHandlers.nomadInspect.postMessage(info);
                    }
                }
                cleanup();
            }

            function onKeyDown(e) {
                if (e.key === 'Escape') {
                    cleanup();
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadInspect) {
                        window.webkit.messageHandlers.nomadInspect.postMessage({ cancel: true });
                    }
                }
            }

            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('click', onClick, true);
            document.addEventListener('keydown', onKeyDown, true);
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func highlightInspectedElement() {
        guard let selector = inspectedElementInfo?.selector, !selector.isEmpty else { return }
        let escaped = selector.replacingOccurrences(of: "'", with: "\\'")
        let script = """
        (function() {
            try {
                const el = document.querySelector('\(escaped)');
                if (!el) return;
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                const prev = el.style.outline;
                const prevTrans = el.style.transition;
                el.style.transition = 'outline 0.15s ease';
                el.style.outline = '3px solid #007aff';
                setTimeout(() => {
                    el.style.outline = prev;
                    el.style.transition = prevTrans;
                }, 1500);
            } catch(e) {}
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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
        let script = """
        (function() {
            if (window.__nomad_zapper_active) return;
            window.__nomad_zapper_active = true;
            let overlay = document.getElementById('__nomad_zap_overlay');
            if (!overlay) {
                overlay = document.createElement('div');
                overlay.id = '__nomad_zap_overlay';
                overlay.style.position = 'fixed';
                overlay.style.pointerEvents = 'none';
                overlay.style.border = '2px dashed #ff3b30';
                overlay.style.backgroundColor = 'rgba(255, 59, 48, 0.18)';
                overlay.style.zIndex = '2147483647';
                overlay.style.transition = 'all 0.05s ease';
                overlay.style.borderRadius = '3px';
                document.body.appendChild(overlay);
            }
            overlay.style.display = 'none';

            function onMouseMove(e) {
                const el = document.elementFromPoint(e.clientX, e.clientY);
                if (!el || el === overlay) return;
                const rect = el.getBoundingClientRect();
                overlay.style.left = rect.left + 'px';
                overlay.style.top = rect.top + 'px';
                overlay.style.width = rect.width + 'px';
                overlay.style.height = rect.height + 'px';
                overlay.style.display = 'block';
            }

            function cleanup() {
                window.__nomad_zapper_active = false;
                document.removeEventListener('mousemove', onMouseMove, true);
                document.removeEventListener('click', onClick, true);
                document.removeEventListener('keydown', onKeyDown, true);
                if (overlay) overlay.style.display = 'none';
            }

            function onClick(e) {
                e.preventDefault();
                e.stopPropagation();
                const el = document.elementFromPoint(e.clientX, e.clientY);
                if (el && el !== overlay) {
                    let sel = el.tagName.toLowerCase();
                    if (el.id) {
                        sel += '#' + el.id;
                    } else if (el.className && typeof el.className === 'string') {
                        const cls = el.className.trim().split(/\\s+/).filter(Boolean).slice(0, 2).join('.');
                        if (cls) sel += '.' + cls;
                    }
                    el.setAttribute('data-nomad-zapped', 'true');
                    el.style.setProperty('display', 'none', 'important');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadZapper) {
                        window.webkit.messageHandlers.nomadZapper.postMessage({
                            host: window.location.host,
                            selector: sel
                        });
                    }
                }
                cleanup();
            }

            function onKeyDown(e) {
                if (e.key === 'Escape') {
                    cleanup();
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadZapper) {
                        window.webkit.messageHandlers.nomadZapper.postMessage({ cancel: true });
                    }
                }
            }

            document.addEventListener('mousemove', onMouseMove, true);
            document.addEventListener('click', onClick, true);
            document.addEventListener('keydown', onKeyDown, true);
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    func stopElementZapper() {
        isZapperActive = false
        let script = """
        (function() {
            window.__nomad_zapper_active = false;
            const overlay = document.getElementById('__nomad_zap_overlay');
            if (overlay) overlay.style.display = 'none';
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    /// Clears all zapped selectors for current host and restores hidden elements on the page immediately
    func unhideAllZappedElements() {
        guard let host = url?.host ?? webView.url?.host else { return }
        ZapperStore.shared.clearSelectors(for: host)
        let script = """
        (function() {
            const s = document.getElementById('nomad-zapped-rules');
            if (s) s.remove();
            document.querySelectorAll('[data-nomad-zapped="true"]').forEach(el => {
                el.style.removeProperty('display');
                el.removeAttribute('data-nomad-zapped');
            });
        })();
        """
        webView.evaluateJavaScript(script, completionHandler: nil)
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

        let script = """
        (function() {
            const title = document.querySelector('h1')?.innerText || document.title || 'Untitled';
            const bylineEl = document.querySelector('[rel="author"], .byline, .author, time, .date');
            const byline = bylineEl ? bylineEl.innerText.trim() : '';
            const siteName = document.querySelector('meta[property="og:site_name"]')?.content || window.location.hostname;

            const candidate = document.querySelector('article, [role="article"], main, .article-body, .post-content') || document.body;
            const pEls = Array.from(candidate.querySelectorAll('p'));
            const paragraphs = pEls
                .map(p => p.innerText.trim())
                .filter(t => t.length > 35 && !t.includes('Cookie') && !t.includes('Privacy Policy'));

            const totalWords = paragraphs.reduce((sum, p) => sum + p.split(/\\s+/).length, 0);
            const readingTime = Math.max(1, Math.round(totalWords / 200));

            return {
                title: title,
                byline: byline,
                siteName: siteName,
                paragraphs: paragraphs,
                wordCount: totalWords,
                readingTime: readingTime
            };
        })();
        """
        webView.evaluateJavaScript(script) { [weak self] result, error in
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

    func handleScriptMessage(name: String, body: Any) {
        if name == "nomadConsole", let dict = body as? [String: Any] {
            let lvlStr = dict["level"] as? String ?? "log"
            let msg = dict["message"] as? String ?? ""
            let level: ConsoleEntry.Level
            switch lvlStr {
            case "error": level = .error
            case "warn": level = .warn
            case "info": level = .info
            default: level = .log
            }
            appendConsoleEntry(level: level, message: msg)
        } else if name == "nomadInspect", let dict = body as? [String: Any] {
            if dict["cancel"] as? Bool == true {
                self.isInspectorActive = false
                return
            }
            let selector = dict["selector"] as? String ?? ""
            let tag = dict["tag"] as? String ?? ""
            let idAttr = dict["idAttr"] as? String ?? ""
            let classes = dict["classes"] as? String ?? ""
            let text = dict["text"] as? String ?? ""
            let width = dict["width"] as? Int ?? 0
            let height = dict["height"] as? Int ?? 0
            let agentId = dict["agentId"] as? String
            self.inspectedElementInfo = InspectedElementInfo(
                selector: selector,
                tag: tag,
                idAttr: idAttr,
                classes: classes,
                text: text,
                width: width,
                height: height,
                agentId: agentId
            )
            self.isInspectorActive = false
        } else if name == "nomadNetwork", let dict = body as? [String: Any] {
            let method = dict["method"] as? String ?? "GET"
            let url = dict["url"] as? String ?? ""
            let status = dict["status"] as? Int ?? 200
            let duration = dict["duration"] as? Int ?? 0
            let type = dict["type"] as? String ?? "fetch"
            let error = dict["error"] as? String
            let entry = NetworkEntry(method: method, url: url, status: status, durationMs: duration, type: type, error: error)
            if self.networkEntries.count > 400 {
                self.networkEntries.removeFirst(50)
            }
            self.networkEntries.append(entry)
        } else if name == "nomadZapper", let dict = body as? [String: Any] {
            self.isZapperActive = false
            if dict["cancel"] as? Bool == true { return }
            if let sel = dict["selector"] as? String, let host = dict["host"] as? String {
                ZapperStore.shared.addSelector(sel, for: host)
            }
        }
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
                ExtensionManager.shared.tabDidChange(self, properties: [.URL])
            }
        })

        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let loading = wv.isLoading
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isLoading = loading
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

        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let canBack = wv.canGoBack
            Task { @MainActor [weak self] in
                self?.canGoBack = canBack
            }
        })

        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let canForward = wv.canGoForward
            Task { @MainActor [weak self] in
                self?.canGoForward = canForward
            }
        })
    }
    // MARK: - Favicon Fetching
    func fetchFavicon(for url: URL) {
        guard url.scheme == "http" || url.scheme == "https", let host = url.host, !host.isEmpty else {
            self.favicon = nil
            return
        }

        if let cached = FaviconService.shared.cachedFavicon(for: host) {
            self.favicon = cached
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            if let image = await FaviconService.shared.loadFavicon(for: url) {
                if self.url?.host == host || self.webView.url?.host == host {
                    self.favicon = image
                }
            }
        }
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate
extension Tab: WKNavigationDelegate, WKUIDelegate {
    // MARK: - Navigation Policy & Security Scheme Validation
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        // Security scheme validation
        if let targetURL = navigationAction.request.url {
            let scheme = targetURL.scheme?.lowercased() ?? ""
            // Disallow untrusted remote web pages from navigating to local file URLs or internal nomad schemes
            if let currentURL = webView.url, currentURL.scheme != "nomad" && (scheme == "nomad" || scheme == "file") {
                decisionHandler(.cancel, preferences)
                return
            }
        }

        decisionHandler(.allow, preferences)
    }

    // MIME type & Content-Disposition check for downloads (.zip, .dmg, .pkg, images with attachment header, etc.)
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // A redirect (3xx) has nowhere to be shown and carries no content of its own, but must be followed
        if let http = navigationResponse.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep (like Wallhaven wallpaper downloads)
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    // Connect WebKit downloads to DownloadManager
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let originalURL = navigationAction.request.url ?? URL(string: "about:blank")!
        DownloadManager.shared.register(download, from: originalURL)
        if self.isBlank || self.webView.url == nil {
            onRequestCloseTab?()
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let originalURL = navigationResponse.response.url ?? URL(string: "about:blank")!
        let suggested = navigationResponse.response.suggestedFilename ?? "download"
        DownloadManager.shared.register(download, from: originalURL, suggestedFilename: suggested)
        if self.isBlank || self.webView.url == nil {
            onRequestCloseTab?()
        }
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        let originalURL = webView.url ?? URL(string: "about:blank")!
        DownloadManager.shared.register(download, from: originalURL)
    }

    // TLS Certificate Validation & Security Challenges
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                var secError: CFError?
                let isValid = SecTrustEvaluateWithError(serverTrust, &secError)
                if isValid {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }

                // Prompt user for untrusted / self-signed certificate
                let host = challenge.protectionSpace.host
                let alert = NSAlert()
                alert.messageText = "Security Warning: Untrusted Certificate"
                alert.informativeText = "The certificate for \"\(host)\" is invalid or self-signed. Visiting this site may compromise your privacy.\n\nDo you want to continue anyway?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Continue Anyway")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.isLoading = false
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
        if let currentURL = webView.url {
            fetchFavicon(for: currentURL)

            // Record visited page in HistoryStore (bypassed in Incognito mode)
            if !self.isIncognito {
                HistoryStore.shared.addVisit(url: currentURL, title: self.title)
            }

            // Apply persistently zapped elements for this domain
            if let host = currentURL.host {
                let css = ZapperStore.shared.cssRule(for: host)
                if !css.isEmpty {
                    let injectScript = """
                    (function() {
                        let s = document.getElementById('nomad-zapped-rules');
                        if (!s) {
                            s = document.createElement('style');
                            s.id = 'nomad-zapped-rules';
                            document.head ? document.head.appendChild(s) : document.documentElement.appendChild(s);
                        }
                        s.textContent = `\(css)`;
                    })();
                    """
                    webView.evaluateJavaScript(injectScript, completionHandler: nil)
                }
            }

            let js = "document.querySelector(\"link[rel~='icon'], link[rel='shortcut icon']\")?.href || \"\""
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self,
                      let hrefString = result as? String,
                      !hrefString.isEmpty,
                      let iconURL = URL(string: hrefString),
                      let host = currentURL.host else { return }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let image = await FaviconService.shared.loadFavicon(fromDirectURL: iconURL, host: host) {
                        if self.url?.host == host || self.webView.url?.host == host {
                            self.favicon = image
                        }
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        self.networkEntries.removeAll()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        print("Tab Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        print("Tab Provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.isLoading = false
        print("Tab WebContent process terminated, automatically reloading...")
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let onOpenTabWithWebView = self.onOpenTabWithWebView {
            return onOpenTabWithWebView(configuration, navigationAction)
        }
        if let targetURL = navigationAction.request.url {
            if let onOpenURLInNewTab = self.onOpenURLInNewTab {
                onOpenURLInNewTab(targetURL)
            } else {
                self.load(url: targetURL)
            }
        }
        return nil
    }
}

// MARK: - Custom Browser WebView with Directional Axis Locking and Fluid Gestures
@MainActor
final class BrowserWebView: WKWebView {
    weak var tab: Tab?

    private enum ActiveScrollAxis {
        case none
        case vertical
        case horizontalSwipe
        case horizontalSuppressed
    }

    private var currentAxis: ActiveScrollAxis = .none
    private var accumulatedX: CGFloat = 0
    private var hasTriggeredHaptic: Bool = false

    override func scrollWheel(with event: NSEvent) {
        guard let tab = tab, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Handle end or cancellation of the scroll gesture
        if event.phase == .ended || event.phase == .cancelled {
            if currentAxis == .horizontalSwipe {
                let direction: Tab.SwipeDirection = accumulatedX > 0 ? .back : .forward
                let shouldCommit = abs(accumulatedX) >= 55
                tab.finishSwipeGesture(commit: shouldCommit, direction: direction)
            }
            currentAxis = .none
            accumulatedX = 0
            hasTriggeredHaptic = false
            super.scrollWheel(with: event)
            return
        }

        // Detect axis when gesture begins
        if event.phase == .began {
            accumulatedX = 0
            hasTriggeredHaptic = false

            // If vertical motion is dominant, lock strictly to vertical axis to eliminate any diagonal wobble
            if abs(deltaY) >= abs(deltaX) {
                currentAxis = .vertical
            } else if abs(deltaX) > abs(deltaY) * 1.5 && abs(deltaX) > 1.5 {
                // Dominant horizontal motion
                if (deltaX > 0 && tab.canGoBack) || (deltaX < 0 && tab.canGoForward) {
                    currentAxis = .horizontalSwipe
                } else {
                    currentAxis = .horizontalSuppressed
                }
            } else {
                currentAxis = .none
            }
        }

        // Process active gestures
        switch currentAxis {
        case .horizontalSwipe:
            if event.phase == .changed {
                accumulatedX += deltaX

                // Cancel if user swipes back against the allowed navigation direction
                if (accumulatedX > 0 && !tab.canGoBack) || (accumulatedX < 0 && !tab.canGoForward) {
                    accumulatedX = 0
                    currentAxis = .none
                    tab.cancelSwipeGesture()
                    super.scrollWheel(with: event)
                    return
                }

                let threshold: CGFloat = 55
                let distance = abs(accumulatedX)
                let progress = min(distance / threshold, 1.25)
                let direction: Tab.SwipeDirection = accumulatedX > 0 ? .back : .forward
                let isTriggered = distance >= threshold

                if isTriggered && !hasTriggeredHaptic {
                    hasTriggeredHaptic = true
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                } else if !isTriggered && hasTriggeredHaptic {
                    hasTriggeredHaptic = false
                }

                tab.updateSwipeGesture(direction: direction, progress: progress, distance: distance, isTriggered: isTriggered)
                return // Fully consume horizontal event so webpage never moves/wobbles!
            }

        case .horizontalSuppressed:
            // Suppress horizontal elastic overscroll wobble at the edges when cannot go back/forward
            if event.phase == .changed {
                return
            }

        case .vertical:
            // Lock to vertical scrolling: eliminate diagonal horizontal drift (deltaX)
            if (event.phase == .changed || event.momentumPhase == .changed) && abs(deltaX) > 0 {
                if let cgCopy = event.cgEvent?.copy() {
                    cgCopy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                    cgCopy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                    if let filteredEvent = NSEvent(cgEvent: cgCopy) {
                        super.scrollWheel(with: filteredEvent)
                        return
                    }
                }
            }
            super.scrollWheel(with: event)
            return

        case .none:
            // Anti-wobble guard for mid-stream events and momentum phases
            if event.phase == .changed || event.momentumPhase == .changed {
                if abs(deltaY) > abs(deltaX) * 1.2 && abs(deltaX) > 0 {
                    // Predominantly vertical: zero out horizontal drift
                    if let cgCopy = event.cgEvent?.copy() {
                        cgCopy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                        cgCopy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                        if let filteredEvent = NSEvent(cgEvent: cgCopy) {
                            super.scrollWheel(with: filteredEvent)
                            return
                        }
                    }
                } else if abs(deltaX) > abs(deltaY) * 2 && abs(deltaX) > 2 {
                    if (deltaX > 0 && !tab.canGoBack) || (deltaX < 0 && !tab.canGoForward) {
                        return // Suppress page wobble at edge
                    }
                }
            }
            super.scrollWheel(with: event)
        }
    }
}

// MARK: - Script Message Handler & Bridge
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var delegate: WKScriptMessageHandler?

    init(delegate: WKScriptMessageHandler) {
        self.delegate = delegate
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        delegate?.userContentController(userContentController, didReceive: message)
    }
}

extension Tab: WKScriptMessageHandler {
    nonisolated func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        Task { @MainActor [weak self] in
            self?.handleScriptMessage(name: message.name, body: message.body)
        }
    }
}


