//
//  BrowserStore.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import Combine
import WebKit

/// Root state container for Nomad browser window.
/// Manages open tabs, the currently focused tab, and browser actions.
@MainActor
final class BrowserStore: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var activeTabId: UUID?
    @Published var isAddressBarFocused: Bool = false

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabId }
    }

    init() {
        // Start with an initial clean blank tab
        _ = newTab(url: nil, select: true, lazy: false)
        ExtensionManager.shared.start(with: self)
    }

    /// Persists open session tabs to disk.
    private func persistSession() {
        SessionManager.shared.save(tabs: tabs, activeTabId: activeTabId)
    }

    /// Creates and appends a new tab.
    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, isIncognito: Bool = false, select: Bool = true, lazy: Bool = false) -> Tab {
        // Prevent opening duplicate empty blank tabs:
        // If requesting a blank new tab (url == nil) and a blank tab already exists, select it instead of duplicating.
        if url == nil && configuration == nil {
            if let active = activeTab, active.isBlank && active.isIncognito == isIncognito {
                return active
            } else if let existingBlank = tabs.first(where: { $0.isBlank && $0.isIncognito == isIncognito }) {
                if select {
                    selectTab(id: existingBlank.id)
                }
                return existingBlank
            }
        }

        let tab = Tab(initialURL: url, configuration: configuration, isIncognito: isIncognito, lazy: lazy)
        
        tab.onOpenURLInNewTab = { [weak self, weak tab] targetURL in
            let isIncog = tab?.isIncognito ?? false
            self?.newTab(url: targetURL, isIncognito: isIncog, select: true)
        }

        tab.onOpenTabWithWebView = { [weak self, weak tab] config, action in
            guard let self else { return nil }
            let targetURL = action.request.url
            let isIncog = tab?.isIncognito ?? false
            let newCreated = self.newTab(url: targetURL, configuration: config, isIncognito: isIncog, select: true)
            return newCreated.webView
        }

        tab.onRequestCloseTab = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            tabs.append(tab)
            if select {
                activeTabId = tab.id
            }
        }
        
        ExtensionManager.shared.didOpenTab(tab)
        if select {
            ExtensionManager.shared.didActivateTab(tab)
        }
        persistSession()
        
        return tab
    }

    /// Creates and opens a new private / incognito tab with isolated ephemeral storage.
    @discardableResult
    func newIncognitoTab(url: URL? = nil) -> Tab {
        newTab(url: url, isIncognito: true, select: true, lazy: false)
    }

    /// Closes the specified tab with smooth spring removal.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        
        let isClosingActive = (activeTabId == id)
        let tab = tabs[index]
        tab.cleanup()
        ExtensionManager.shared.didCloseTab(id: id)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            tabs.remove(at: index)
            
            // If the closed tab was active, choose an adjacent tab
            if isClosingActive {
                if tabs.isEmpty {
                    // Keep at least one tab open
                    newTab(url: nil, select: true)
                } else {
                    let nextIndex = min(index, tabs.count - 1)
                    activeTabId = tabs[nextIndex].id
                }
            }
        }
        persistSession()
    }

    /// Selects a tab by ID with smooth content transition.
    func selectTab(id: UUID) {
        if tabs.contains(where: { $0.id == id }), activeTabId != id {
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTabId = id
            }
            if let tab = tabs.first(where: { $0.id == id }) {
                tab.ensureLoaded()
                ExtensionManager.shared.didActivateTab(tab)
            }
            persistSession()
        }
    }

    /// Reorders a tab from one index to another with animated sliding.
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              tabs.indices.contains(sourceIndex),
              tabs.indices.contains(destinationIndex) else { return }
        
        var updated = tabs
        let tab = updated.remove(at: sourceIndex)
        updated.insert(tab, at: destinationIndex)
        tabs = updated
    }

    /// Selects the previous tab (⌘{ or Ctrl+Shift+Tab)
    func selectPreviousTab() {
        guard let currentId = activeTabId, let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        withAnimation(.easeInOut(duration: 0.18)) {
            activeTabId = tabs[prevIndex].id
        }
    }

    /// Selects the next tab (⌘} or Ctrl+Tab)
    func selectNextTab() {
        guard let currentId = activeTabId, let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        withAnimation(.easeInOut(duration: 0.18)) {
            activeTabId = tabs[nextIndex].id
        }
    }

    // MARK: - Navigation convenience forwards
    func goBack() {
        activeTab?.goBack()
    }

    func goForward() {
        activeTab?.goForward()
    }

    func reload() {
        activeTab?.reload()
    }

    /// Opens or switches to the settings internal page (nomad://settings).
    func openSettings(section: String? = nil) {
        if let section = section {
            SettingsStore.shared.activeSection = section
        }
        let settingsURL = URL(string: "nomad://settings")!
        if let current = activeTab, current.isBlank {
            current.load(url: settingsURL)
        } else if let existing = tabs.first(where: { $0.url?.host == "settings" }) {
            selectTab(id: existing.id)
        } else {
            newTab(url: settingsURL, select: true)
        }
    }

    /// Opens or switches to the General settings section (legacy tune forwarder).
    func openTune() {
        openSettings(section: "General")
    }

    /// Opens a bookmark in the current or new tab.
    func openBookmark(_ bookmark: Bookmark) {
        if let destination = URL(string: bookmark.url) {
            if let current = activeTab, current.isBlank {
                current.load(url: destination)
            } else {
                newTab(url: destination, select: true)
            }
        }
    }
}
