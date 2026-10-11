//
//  BrowserStore.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import Combine

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
        // Start with an initial blank tab
        let initialTab = newTab(url: nil, select: true)
        _ = initialTab
    }

    /// Creates and appends a new tab.
    @discardableResult
    func newTab(url: URL? = nil, select: Bool = true) -> Tab {
        let tab = Tab(initialURL: url)
        
        tab.onOpenURLInNewTab = { [weak self] targetURL in
            self?.newTab(url: targetURL, select: true)
        }
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            tabs.append(tab)
            if select {
                activeTabId = tab.id
            }
        }
        
        return tab
    }

    /// Closes the specified tab with smooth spring removal.
    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        
        let isClosingActive = (activeTabId == id)
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
    }

    /// Selects a tab by ID with smooth content transition.
    func selectTab(id: UUID) {
        if tabs.contains(where: { $0.id == id }), activeTabId != id {
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTabId = id
            }
        }
    }

    /// Reorders a tab from one index to another with animated sliding.
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              tabs.indices.contains(sourceIndex),
              tabs.indices.contains(destinationIndex) else { return }
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            let tab = tabs.remove(at: sourceIndex)
            tabs.insert(tab, at: destinationIndex)
        }
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
    func openSettings() {
        let settingsURL = URL(string: "nomad://settings")!
        if let current = activeTab, current.isBlank {
            current.load(url: settingsURL)
        } else if let existing = tabs.first(where: { $0.url == settingsURL }) {
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
