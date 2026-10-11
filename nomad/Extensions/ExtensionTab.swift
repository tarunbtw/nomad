//
//  ExtensionTab.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import AppKit
import WebKit

/// Adapter conforming to Apple's `WKWebExtensionTab` protocol.
/// Connects a Nomad `Tab` instance to the WebKit extension runtime.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    weak var tab: Tab?
    unowned let manager: ExtensionManager

    init(tab: Tab, manager: ExtensionManager) {
        self.tab = tab
        self.manager = manager
        super.init()
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        manager.currentWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        guard let tab, let store = manager.store else { return NSNotFound }
        return store.tabs.firstIndex(where: { $0.id == tab.id }) ?? NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(tab?.isLoading ?? false)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        tab?.id == manager.store?.activeTabId
    }

    func isPinned(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func isPlayingAudio(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        true
    }

    func activate(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        manager.store?.selectTab(id: tab.id)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        tab.load(url: url)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext) async throws {
        tab?.reload()
    }

    func goBack(for context: WKWebExtensionContext) async throws {
        tab?.goBack()
    }

    func goForward(for context: WKWebExtensionContext) async throws {
        tab?.goForward()
    }

    func close(for context: WKWebExtensionContext) async throws {
        guard let tab else { return }
        manager.store?.closeTab(id: tab.id)
    }
}
