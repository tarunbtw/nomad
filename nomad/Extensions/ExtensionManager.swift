//
//  ExtensionManager.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import AppKit
import SwiftUI
import WebKit
import Combine

/// Central coordinator for WebExtensions in Nomad.
/// Manages WKWebExtensionController, extension lifecycles, CRX installation, and delegate events.
@MainActor
final class ExtensionManager: NSObject, ObservableObject {
    static let shared = ExtensionManager()

    /// Custom URL scheme for extensions (e.g. chrome-extension://<id>/).
    static let scheme = "chrome-extension"

    /// Application Support/nomad/Extensions/ directory.
    static var extensionsFolder: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let nomadDir = appSupport.appendingPathComponent("nomad", isDirectory: true)
        return nomadDir.appendingPathComponent("Extensions", isDirectory: true)
    }

    private static var listFileURL: URL {
        extensionsFolder.appendingPathComponent("installed.json")
    }

    let controller: WKWebExtensionController

    @Published private(set) var installed: [InstalledExtension] = []
    @Published private(set) var contexts: [String: WKWebExtensionContext] = [:]
    @Published private(set) var actionsChanged: Int = 0
    @Published private(set) var busy: String? = nil

    /// Active browser store reference.
    weak var store: BrowserStore? {
        didSet {
            // Update active window bindings when store changes
        }
    }

    private var adapters: [UUID: ExtensionTab] = [:]
    var anchors: [String: WeakView] = [:]
    lazy var currentWindow: ExtensionWindow = ExtensionWindow(manager: self)

    /// Finds the NSView anchor for an extension's button, falling back to the puzzle menu anchor.
    func anchor(for id: String) -> NSView? {
        let own = anchors[id]?.view
        return own?.window != nil ? own : anchors["extensions_menu_anchor"]?.view
    }

    private override init() {
        WKWebExtension.MatchPattern.registerCustomURLScheme(ExtensionManager.scheme)
        let config = WKWebExtensionController.Configuration.default()
        self.controller = WKWebExtensionController(configuration: config)
        super.init()
        self.controller.delegate = self
        loadPersistedList()
    }

    /// Attaches the shared extension controller to a tab's WKWebViewConfiguration.
    func attach(_ configuration: WKWebViewConfiguration) {
        configuration.webExtensionController = controller
    }

    /// Obtains or creates the ExtensionTab adapter for a Nomad tab.
    func adapter(for tab: Tab) -> ExtensionTab {
        if let existing = adapters[tab.id] {
            return existing
        }
        let created = ExtensionTab(tab: tab, manager: self)
        adapters[tab.id] = created
        return created
    }

    /// Clean up adapter when tab closes.
    func removeAdapter(for tabId: UUID) {
        adapters.removeValue(forKey: tabId)
    }

    func didOpenTab(_ tab: Tab) {
        let tabAdapter = adapter(for: tab)
        controller.didOpenTab(tabAdapter)
    }

    func didCloseTab(id: UUID) {
        if let existing = adapters[id] {
            controller.didCloseTab(existing, windowIsClosing: false)
            adapters.removeValue(forKey: id)
        }
    }

    func didActivateTab(_ tab: Tab) {
        let tabAdapter = adapter(for: tab)
        controller.didActivateTab(tabAdapter, previousActiveTab: nil)
    }

    /// Notifies the extension controller that tab properties (URL, title, loading) changed.
    func tabDidChange(_ tab: Tab, properties: WKWebExtension.TabChangedProperties) {
        if let adapter = adapters[tab.id] {
            controller.didChangeTabProperties(properties, for: adapter)
        }
    }

    // MARK: - Startup & Lifecycle

    /// Loads all enabled extensions on application startup.
    func start(with store: BrowserStore) {
        self.store = store
        Task {
            for item in installed where item.enabled {
                _ = await load(item)
            }
        }
    }

    /// Loads an individual extension into WebKit.
    func load(_ item: InstalledExtension) async -> Bool {
        let folder = ExtensionManager.extensionsFolder.appendingPathComponent(item.id, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return false }

        // Inject Nomad Chrome API polyfills/shims before WebKit reads the package
        try? await Task.detached(priority: .userInitiated) {
            try ExtensionShims.prepare(folder)
        }.value

        do {
            let extensionObj = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: extensionObj)
            context.uniqueIdentifier = item.id
            context.isInspectable = true

            // Set stable origin and baseURL matching the extension ID (chrome-extension://<id>/)
            // Essential for Phantom, Trust Wallet, and standard extensions to preserve IndexedDB/storage
            if let stable = URL(string: "\(ExtensionManager.scheme)://\(item.id)/") {
                context.baseURL = stable
            }

            // Automatically grant requested permissions approved during installation
            for permission in extensionObj.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            
            // Grant all requested match patterns (host permissions for RPC/API endpoints like Solana and Ethereum)
            for pattern in extensionObj.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }

            // Explicitly grant the extension's own origin patterns
            if let ownChrome = try? WKWebExtension.MatchPattern(string: "\(ExtensionManager.scheme)://\(item.id)/*") {
                context.setPermissionStatus(.grantedExplicitly, for: ownChrome)
            }
            if let ownWebkit = try? WKWebExtension.MatchPattern(string: "webkit-extension://\(item.id)/*") {
                context.setPermissionStatus(.grantedExplicitly, for: ownWebkit)
            }

            for string in ["file:///*", "file://*/*"] {
                if let files = try? WKWebExtension.MatchPattern(string: string) {
                    context.setPermissionStatus(.deniedExplicitly, for: files)
                }
            }

            // Sign-in / OAuth address
            if let own = try? WKWebExtension.MatchPattern(string: "https://\(item.id).chromiumapp.org/*") {
                context.setPermissionStatus(.grantedExplicitly, for: own)
            }

            try controller.load(context)
            contexts[item.id] = context
            actionsChanged += 1
            return true
        } catch {
            NSLog("[Nomad Extensions] Failed to load %@: %@", item.id, error.localizedDescription)
            return false
        }
    }

    /// Unloads an extension from WebKit.
    func unload(id: String) {
        guard let context = contexts[id] else { return }
        ExtensionPopup.shared.close()
        ExtensionOffscreen.close(for: id)
        try? controller.unload(context)
        contexts.removeValue(forKey: id)
        actionsChanged += 1
    }

    // MARK: - User Operations

    /// Installs an extension from a Chrome Web Store link or raw 32-letter ID.
    func installFromWebStore(idOrURL: String) async throws {
        guard let id = CrxDownloader.extractID(from: idOrURL) else {
            throw CrxDownloader.DownloadError.invalidIDOrURL
        }

        busy = "Installing..."
        defer { busy = nil }

        let targetFolder = ExtensionManager.extensionsFolder.appendingPathComponent(id, isDirectory: true)
        let installedExt = try await CrxDownloader.downloadAndUnpack(id: id, destinationFolder: targetFolder)

        // Remove existing entry if re-installing/updating
        installed.removeAll(where: { $0.id == id })
        installed.append(installedExt)
        save()

        _ = await load(installedExt)
    }

    /// Loads an unpacked developer extension folder.
    func installUnpacked(folderURL: URL) async throws {
        busy = "Loading..."
        defer { busy = nil }

        let installedExt = try await CrxDownloader.installUnpacked(folderURL: folderURL, destinationFolder: ExtensionManager.extensionsFolder)

        installed.removeAll(where: { $0.id == installedExt.id })
        installed.append(installedExt)
        save()

        _ = await load(installedExt)
    }

    /// Toggles an extension enabled/disabled.
    func toggleEnabled(id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].enabled.toggle()
        let isNowEnabled = installed[index].enabled
        save()

        if isNowEnabled {
            let item = installed[index]
            Task { _ = await load(item) }
        } else {
            unload(id: id)
        }
    }

    /// Toggles whether an extension is pinned to the top toolbar.
    func togglePinned(id: String) {
        guard let index = installed.firstIndex(where: { $0.id == id }) else { return }
        installed[index].pinned.toggle()
        save()
        actionsChanged += 1
    }

    /// Uninstalls and deletes an extension completely.
    func remove(id: String) {
        unload(id: id)
        installed.removeAll(where: { $0.id == id })
        save()

        let folder = ExtensionManager.extensionsFolder.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
    }

    /// Opens an extension's options page in a new browser tab.
    func openOptionsPage(for id: String) {
        guard let context = contexts[id] else { return }
        if let url = context.optionsPageURL {
            store?.newTab(url: url, configuration: context.webViewConfiguration, select: true)
        } else if let ext = installed.first(where: { $0.id == id }),
                  let optionsPath = ext.optionsPath,
                  let url = URL(string: optionsPath, relativeTo: context.baseURL) {
            store?.newTab(url: url, configuration: context.webViewConfiguration, select: true)
        }
    }

    /// Obtains the specialized WKWebViewConfiguration for an extension URL if loaded.
    func configuration(for url: URL?) -> WKWebViewConfiguration? {
        guard let url, let host = url.host,
              url.scheme == ExtensionManager.scheme || url.scheme == "webkit-extension" else {
            return nil
        }
        return contexts[host]?.webViewConfiguration
    }

    /// Activates an extension: opens its popup or fires its action.
    func activate(_ id: String) {
        guard let context = contexts[id] else { return }
        if ExtensionPopup.shared.closes(id) { return }

        let activeAdapter = store?.activeTab.flatMap { adapter(for: $0) }

        // If the extension declares a default popup (like Phantom, Trust Wallet, uBlock), open its popup directly!
        if let url = ExtensionManager.popupURL(for: context) {
            ExtensionPopup.shared.show(url, for: context, from: anchor(for: id))
            return
        }

        context.performAction(for: activeAdapter)
    }

    /// Resolves the declared popup URL for an extension's action.
    static func popupURL(for context: WKWebExtensionContext) -> URL? {
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        if let path = action?["default_popup"] as? String, !path.isEmpty {
            return URL(string: path, relativeTo: context.baseURL)?.absoluteURL
        }
        return nil
    }

    /// Resolves a fallback page (e.g. home.html, onboarding.html, popup.html) if an extension opens a bare scheme URL
    static func defaultPage(for context: WKWebExtensionContext) -> String? {
        let folder = ExtensionManager.extensionsFolder.appendingPathComponent(context.uniqueIdentifier, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("home.html").path) {
            return "home.html"
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("onboarding.html").path) {
            return "onboarding.html"
        }
        let manifest = context.webExtension.manifest
        let action = (manifest["action"] ?? manifest["browser_action"]) as? [String: Any]
        if let popup = action?["default_popup"] as? String, !popup.isEmpty {
            return popup
        }
        if let sidePanel = manifest["side_panel"] as? [String: Any],
           let path = sidePanel["default_path"] as? String, !path.isEmpty {
            return path
        }
        return "popup.html"
    }

    // MARK: - Persistence

    private func save() {
        try? FileManager.default.createDirectory(at: ExtensionManager.extensionsFolder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(installed) {
            try? data.write(to: ExtensionManager.listFileURL, options: .atomic)
        }
    }

    private func loadPersistedList() {
        if let data = try? Data(contentsOf: ExtensionManager.listFileURL),
           let list = try? JSONDecoder().decode([InstalledExtension].self, from: data) {
            self.installed = list
        }
    }
}

/// A weak reference to an NSView for anchor positioning.
@MainActor
final class WeakView {
    weak var view: NSView?
    init(_ view: NSView) {
        self.view = view
    }
}

// MARK: - WKWebExtensionControllerDelegate
extension ExtensionManager: WKWebExtensionControllerDelegate {
    func webExtensionController(_ controller: WKWebExtensionController, openWindowsFor extensionContext: WKWebExtensionContext) -> [any WKWebExtensionWindow] {
        [currentWindow]
    }

    func webExtensionController(_ controller: WKWebExtensionController, focusedWindowFor extensionContext: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        currentWindow
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewTabUsing configuration: WKWebExtension.TabConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionTab)? {
        guard let store else { return nil }
        var url = configuration.url ?? URL(string: "about:blank")!
        if url.scheme == nil || url.scheme?.isEmpty == true {
            if let resolved = URL(string: url.relativeString, relativeTo: extensionContext.baseURL)?.absoluteURL {
                url = resolved
            }
        } else if url.scheme == ExtensionManager.scheme && (url.path.isEmpty || url.path == "/") {
            if let fallback = ExtensionManager.defaultPage(for: extensionContext),
               let resolved = URL(string: fallback, relativeTo: extensionContext.baseURL)?.absoluteURL {
                url = resolved
            }
        }
        let newTab = store.newTab(url: url, configuration: extensionContext.webViewConfiguration, select: configuration.shouldBeActive)
        return adapter(for: newTab)
    }

    func webExtensionController(_ controller: WKWebExtensionController, openNewWindowUsing configuration: WKWebExtension.WindowConfiguration, for extensionContext: WKWebExtensionContext) async throws -> (any WKWebExtensionWindow)? {
        guard let store else { return nil }
        let urls = configuration.tabURLs
        let targetURLs = urls.isEmpty ? [URL(string: "about:blank")!] : urls
        for (idx, mutURL) in targetURLs.enumerated() {
            var url = mutURL
            if url.scheme == nil || url.scheme?.isEmpty == true {
                if let resolved = URL(string: url.relativeString, relativeTo: extensionContext.baseURL)?.absoluteURL {
                    url = resolved
                }
            } else if url.scheme == ExtensionManager.scheme && (url.path.isEmpty || url.path == "/") {
                if let fallback = ExtensionManager.defaultPage(for: extensionContext),
                   let resolved = URL(string: fallback, relativeTo: extensionContext.baseURL)?.absoluteURL {
                    url = resolved
                }
            }
            store.newTab(url: url, configuration: extensionContext.webViewConfiguration, select: idx == 0)
        }
        return currentWindow
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let url = action.popupWebView?.url ?? ExtensionManager.popupURL(for: extensionContext)
        action.closePopup()
        if let url {
            ExtensionPopup.shared.show(url, for: extensionContext, from: anchor(for: extensionContext.uniqueIdentifier))
        }
        completionHandler(nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext
    ) async throws -> Any? {
        let target = applicationIdentifier ?? ExtensionShims.application
        if target == ExtensionShims.application || target.hasPrefix("search") || target.hasPrefix("nomad") {
            return try await ExtensionShims.answer(message, from: extensionContext, manager: self)
        }
        return nil
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext
    ) async throws {
        let app = port.applicationIdentifier ?? ""
        if app == ExtensionShims.application || app.hasPrefix("search") || app.hasPrefix("nomad") {
            return
        }
    }
}
