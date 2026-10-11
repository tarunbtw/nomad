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
    lazy var currentWindow: ExtensionWindow = ExtensionWindow(manager: self)

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

        do {
            let extensionObj = try await WKWebExtension(resourceBaseURL: folder)
            let context = WKWebExtensionContext(for: extensionObj)
            context.uniqueIdentifier = item.id

            if let baseURL = URL(string: "\(ExtensionManager.scheme)://\(item.id)/") {
                context.baseURL = baseURL
            }
            context.isInspectable = true

            // Automatically grant requested permissions approved during installation
            for permission in extensionObj.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in extensionObj.requestedPermissionMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
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
        guard let ext = installed.first(where: { $0.id == id }),
              let optionsPath = ext.optionsPath,
              let url = URL(string: "\(ExtensionManager.scheme)://\(id)/\(optionsPath)") else { return }
        store?.newTab(url: url, select: true)
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
        let url = configuration.url ?? URL(string: "about:blank")!
        store.newTab(url: url, select: configuration.shouldBeActive)
        guard let newTab = store.tabs.last else { return nil }
        return adapter(for: newTab)
    }
}
