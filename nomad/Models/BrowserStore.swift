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
        let restoredURLs = SessionManager.shared.restore()
        if !restoredURLs.isEmpty {
            for (idx, url) in restoredURLs.enumerated() {
                newTab(url: url, select: idx == 0, lazy: idx != 0)
            }
        } else {
            // Start with an initial blank tab
            _ = newTab(url: nil, select: true, lazy: false)
        }
        ExtensionManager.shared.start(with: self)
    }

    /// Persists open session tabs to disk.
    private func persistSession() {
        SessionManager.shared.save(tabs: tabs, activeTabId: activeTabId)
    }

    /// Creates and appends a new tab.
    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, select: Bool = true, lazy: Bool = false) -> Tab {
        let tab = Tab(initialURL: url, configuration: configuration, lazy: lazy)
        
        tab.onOpenURLInNewTab = { [weak self] targetURL in
            self?.newTab(url: targetURL, select: true)
        }

        tab.onOpenTabWithWebView = { [weak self] config, action in
            guard let self else { return nil }
            let targetURL = action.request.url
            let newCreated = self.newTab(url: targetURL, configuration: config, select: true)
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

    /// Closes the specified tab with smooth spring removal.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        
        let isClosingActive = (activeTabId == id)
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

    /// Opens or switches to the tune internal page (nomad://tune).
    func openTune() {
        let tuneURL = URL(string: "nomad://tune")!
        if let current = activeTab, current.isBlank {
            current.load(url: tuneURL)
        } else if let existing = tabs.first(where: { $0.url == tuneURL }) {
            selectTab(id: existing.id)
        } else {
            newTab(url: tuneURL, select: true)
        }
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
