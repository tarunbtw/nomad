//
//  ExtensionWindow.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import AppKit
import WebKit

/// Adapter conforming to Apple's `WKWebExtensionWindow` protocol.
/// Represents Nomad's browser window to the WebKit extension runtime.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    unowned let manager: ExtensionManager

    init(manager: ExtensionManager) {
        self.manager = manager
        super.init()
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let store = manager.store else { return [] }
        return store.tabs.map { manager.adapter(for: $0) }
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        guard let store = manager.store, let activeTab = store.activeTab else { return nil }
        return manager.adapter(for: activeTab)
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType {
        .normal
    }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func isFocused(for context: WKWebExtensionContext) -> Bool {
        true
    }
}
