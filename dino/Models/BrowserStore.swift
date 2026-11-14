//
//  BrowserStore.swift
//  dino
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import Combine
import WebKit

/// Named contextual workspace grouping tabs with an icon and accent color.
struct Space: Identifiable, Codable, Equatable {
    var id: UUID
    var name: String
    var icon: String // SF Symbol: e.g. "person.fill", "briefcase.fill", "sparkles", "globe"
    var colorHex: String
    var sharesWithId: UUID? = nil

    static let defaultFirstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
    static let defaultSecondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002") ?? UUID()

    static let defaultSpaces: [Space] = [
        Space(id: defaultFirstID, name: "Personal", icon: "person.fill", colorHex: "#3B82F6"),
        Space(id: defaultSecondID, name: "Work", icon: "briefcase.fill", colorHex: "#10B981")
    ]
}

/// Root state container for Dino browser window.
/// Manages open tabs, the currently focused tab, and browser actions.
@MainActor
final class BrowserStore: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var activeTabId: UUID?
    @Published var isAddressBarFocused: Bool = false
    @Published var isEditingCurrentURL: Bool = false
    @Published var splitPairs: [SplitPair] = []
    @Published var spaces: [Space] = Space.defaultSpaces
    @Published var activeSpaceId: UUID = Space.defaultFirstID
    @Published var isShowingNewSpaceSheet: Bool = false
    @Published var isShowingArcImportModal: Bool = false
    @Published var isShowingExtensionsModal: Bool = false
    @Published var peekTab: Tab? = nil
    @Published var peekFromTabId: UUID? = nil
    @Published var isAutopilotRailVisible: Bool = false
    @Published var draggingTabId: UUID? = nil

    // MARK: - Split Picker State
    @Published var splitPickAnchor: Tab? = nil
    @Published var splitPickSide: SplitSide = .left
    var isPickingSplit: Bool { splitPickAnchor != nil }

    // MARK: - Window Fullscreen & Menu Bar Glide
    @Published var isFullScreen: Bool = false
    @Published var menuBarDrop: CGFloat = 0

    // MARK: - Quick Switcher (⌃Tab) State
    @Published var isQuickSwitcherVisible: Bool = false
    @Published var quickSwitcherPickedId: UUID? = nil
    @Published var tabSnapshots: [UUID: NSImage] = [:]

    struct ClosedTabSnapshot {
        let url: URL?
        let title: String
        let isIncognito: Bool
    }

    @Published var recentlyClosedTabs: [ClosedTabSnapshot] = []

    var activeTab: Tab? {
        tabs.first { $0.id == activeTabId }
    }

    var activeSplitPair: SplitPair? {
        guard let currentId = activeTabId else { return nil }
        return splitPairs.first { $0.contains(currentId) }
    }

    var activeSpace: Space {
        spaces.first { $0.id == activeSpaceId } ?? spaces[0]
    }

    /// Tab in the active space that is playing audio out of sight (for the Mini Player).
    var miniPlayerTab: Tab? {
        tabs.first {
            $0.spaceId == activeSpaceId &&
            ($0.isPlayingAudio || $0.isAudioPausedByPlayer) &&
            $0.id != activeTabId &&
            !$0.isBlank &&
            !$0.isGhost
        }
    }

    /// Tabs visible in the current view context: all pinned tabs + unpinned tabs belonging to the active space (excluding background ghost tabs).
    var visibleTabs: [Tab] {
        tabs.filter { tab in
            !tab.isGhost && (tab.isPinned || tab.spaceId == activeSpaceId || tab.spaceId == nil)
        }
    }

    // MARK: - Phase 1: Tab Lifecycle, Grouping & Basecamp
    @Published var tabGroups: [TabGroup] = []
    @Published var renamingGroupId: UUID? = nil
    @Published var unseenTidiedSpaces: Set<UUID> = []

    var basecampTabs: [Tab] {
        tabs.filter { ($0.place == .basecamp || $0.isPinned) && !$0.isGhost && ($0.spaceId == activeSpaceId || $0.spaceId == nil) }
    }

    var openTabs: [Tab] {
        tabs.filter { $0.place == .open && !$0.isPinned && !$0.isGhost && ($0.spaceId == activeSpaceId || $0.spaceId == nil) }
    }

    var driftedTabs: [Tab] {
        tabs.filter { $0.place == .drifted && !$0.isGhost && ($0.spaceId == activeSpaceId || $0.spaceId == nil) }
    }

    var looseTabs: [Tab] {
        openTabs.filter { $0.groupId == nil }
    }

    var tabGroupsForActiveSpace: [TabGroup] {
        tabGroups.filter { $0.spaceId == activeSpaceId }
    }

    var hasUnseenTidied: Bool {
        unseenTidiedSpaces.contains(activeSpaceId) && !driftedTabs.isEmpty
    }

    func tabs(in group: TabGroup) -> [Tab] {
        tabs.filter { $0.groupId == group.id && $0.place == .open && !$0.isGhost }
    }

    func markTidiedSeen() {
        unseenTidiedSpaces.remove(activeSpaceId)
    }

    @discardableResult
    func createTabGroup(name: String = TabGroup.defaultName, spaceId: UUID? = nil, initialTabId: UUID? = nil) -> TabGroup {
        let sid = spaceId ?? activeSpaceId
        let newGroup = TabGroup(spaceId: sid, name: name)
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tabGroups.append(newGroup)
            if let initialTabId, let tab = tabs.first(where: { $0.id == initialTabId }) {
                tab.groupId = newGroup.id
            }
            renamingGroupId = newGroup.id
        }
        persistSession()
        return newGroup
    }

    /// Automatically dissolves empty tab groups.
    func pruneEmptyGroups() {
        let occupiedGroupIds = Set(tabs.compactMap(\.groupId))
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tabGroups.removeAll { !occupiedGroupIds.contains($0.id) }
        }
    }

    func toggleFoldGroup(id: UUID) {
        guard let idx = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tabGroups[idx].isFolded.toggle()
        }
        persistSession()
    }

    func renameGroup(id: UUID, name: String) {
        guard let idx = tabGroups.firstIndex(where: { $0.id == id }) else { return }
        let clean = TabGroup.cleanName(name) ?? TabGroup.defaultName
        tabGroups[idx].name = clean
        if renamingGroupId == id {
            renamingGroupId = nil
        }
        persistSession()
    }

    func removeGroup(id: UUID) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            for tab in tabs where tab.groupId == id {
                tab.groupId = nil
            }
            tabGroups.removeAll { $0.id == id }
            if renamingGroupId == id {
                renamingGroupId = nil
            }
        }
        persistSession()
    }

    func moveTab(tabId: UUID, toGroupId: UUID?) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tab.groupId = toGroupId
            if let toGroupId, let idx = tabGroups.firstIndex(where: { $0.id == toGroupId }) {
                tabGroups[idx].isFolded = false
            }
            pruneEmptyGroups()
        }
        persistSession()
    }

    func addToBasecamp(tab: Tab) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tab.place = .basecamp
            tab.isPinned = true
            tab.homeURL = tab.url
            tab.groupId = nil
        }
        persistSession()
    }

    func removeFromBasecamp(tab: Tab) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tab.place = .open
            tab.isPinned = false
        }
        persistSession()
    }

    func drift(tab: Tab) {
        guard tab.place == .open && !tab.isPinned && tab.groupId == nil else { return }
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tab.place = .drifted
            tab.driftedAt = Date()
            if let sid = tab.spaceId {
                unseenTidiedSpaces.insert(sid)
            }
            if activeTabId == tab.id {
                let remaining = openTabs.filter { $0.id != tab.id }
                activeTabId = remaining.first?.id
            }
        }
        persistSession()
    }

    func restoreDrifted(tab: Tab) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            tab.place = .open
            tab.driftedAt = nil
            tab.lastActiveTime = Date()
            activeTabId = tab.id
        }
        persistSession()
    }

    func restoreAllDrifted() {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
            for tab in driftedTabs {
                tab.place = .open
                tab.driftedAt = nil
                tab.lastActiveTime = Date()
            }
            unseenTidiedSpaces.remove(activeSpaceId)
        }
        persistSession()
    }

    func checkDrift() {
        let cutoff = Date().addingTimeInterval(-12 * 3600)
        let toDrift = tabs.filter {
            $0.place == .open &&
            !$0.isPinned &&
            $0.groupId == nil &&
            !$0.isFloatingVideo &&
            $0.lastActiveTime < cutoff &&
            $0.id != activeTabId
        }
        for tab in toDrift {
            drift(tab: tab)
        }
    }

    var pinnedTabs: [Tab] {
        tabs.filter { ($0.place == .basecamp || $0.isPinned) && !$0.isGhost }
    }

    var ghostTabs: [Tab] {
        tabs.filter { $0.isGhost }
    }

    init() {
        if let session = DinoHeadlessManager.isHeadless ? nil : SessionManager.shared.restoreSession(), !session.tabs.isEmpty {
            self.tabGroups = session.groups
            for (idx, record) in session.tabs.enumerated() {
                let tab = newTab(url: record.url, select: idx == 0, lazy: idx != 0)
                tab.spaceId = record.spaceId
                tab.place = record.place
                tab.isPinned = (record.place == .basecamp)
                tab.groupId = record.groupId
                tab.homeURL = record.homeURL
            }
        } else {
            let restoredURLs = DinoHeadlessManager.isHeadless ? [] : SessionManager.shared.restore()
            if !restoredURLs.isEmpty {
                for (idx, url) in restoredURLs.enumerated() {
                    _ = newTab(url: url, select: idx == 0, lazy: idx != 0)
                }
            }
            pruneEmptyGroups()
        }
        ExtensionManager.shared.start(with: self)
        DinoAgentServer.shared.start(store: self)

        NotificationCenter.default.addObserver(
            forName: .dinoThemeDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notif in
            MainActor.assumeIsolated {
                let appearance = notif.object as? NSAppearance
                self?.tabs.forEach { $0.webView.appearance = appearance }
            }
        }
    }

    /// Persists open session tabs to disk (excluding background ghost tabs and incognito tabs).
    func persistSession() {
        let persistentTabs = tabs.filter { !$0.isGhost && !$0.isIncognito }
        SessionManager.shared.save(tabs: persistentTabs, groups: tabGroups, activeTabId: activeTabId)
    }

    /// Creates and appends a new tab.
    @discardableResult
    func newTab(url: URL? = nil, configuration: WKWebViewConfiguration? = nil, isIncognito: Bool = false, isGhost: Bool = false, select: Bool = true, lazy: Bool = false) -> Tab {
        // Prevent opening duplicate empty blank tabs (non-ghost only):
        // If requesting a blank new tab (url == nil) and a blank tab already exists, select it instead of duplicating.
        if url == nil && configuration == nil && !isGhost {
            if let active = activeTab, active.isBlank && active.isIncognito == isIncognito && !active.isGhost {
                return active
            } else if let existingBlank = tabs.first(where: { $0.isBlank && $0.isIncognito == isIncognito && !$0.isGhost }) {
                if select {
                    selectTab(id: existingBlank.id)
                }
                return existingBlank
            }
        }

        // Prevent opening duplicate settings tabs: switch to existing settings tab if present
        if let targetURL = url, targetURL.scheme == "dino", targetURL.host == "settings", !isGhost {
            if let existingSettings = tabs.first(where: { $0.isInternalPage && !$0.isGhost }) {
                if select {
                    selectTab(id: existingSettings.id)
                }
                return existingSettings
            }
        }

        let tab = Tab(initialURL: url, configuration: configuration, isIncognito: isIncognito, isGhost: isGhost, lazy: lazy)
        tab.spaceId = activeSpaceId
        
        tab.onOpenURLInNewTab = { [weak self, weak tab] targetURL in
            guard let self else { return }
            let isIncog = (tab?.wantsNextNewTabIncognito == true) || (tab?.isIncognito ?? false)
            tab?.wantsNextNewTabIncognito = false
            if tab?.wantsNextNewTabInSplit == true {
                tab?.wantsNextNewTabInSplit = false
                let newCreated = self.newTab(url: targetURL, isIncognito: isIncog, select: true)
                if let tab = tab {
                    self.splitTab(primaryId: tab.id, secondaryId: newCreated.id)
                }
            } else {
                self.newTab(url: targetURL, isIncognito: isIncog, select: true)
            }
        }

        tab.onOpenTabWithWebView = { [weak self, weak tab] config, action in
            guard let self else { return nil }
            let targetURL = action.request.url
            let isIncog = (tab?.wantsNextNewTabIncognito == true) || (tab?.isIncognito ?? false)
            tab?.wantsNextNewTabIncognito = false
            let newCreated = self.newTab(url: targetURL, configuration: config, isIncognito: isIncog, select: true)
            if tab?.wantsNextNewTabInSplit == true {
                tab?.wantsNextNewTabInSplit = false
                if let tab = tab {
                    self.splitTab(primaryId: tab.id, secondaryId: newCreated.id)
                }
            }
            return newCreated.webView
        }

        tab.onRequestCloseTab = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }

        tab.onRequestNewTab = { [weak self] url in
            if let url {
                self?.newTab(url: url, select: true)
            } else {
                self?.isAddressBarFocused = true
            }
        }

        tab.onRequestPeek = { [weak self, weak tab] targetURL in
            guard let self = self, let tab = tab else { return }
            self.peek(targetURL, from: tab)
        }

        tab.onRequestDuplicateTab = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.newTab(url: tab.url, isIncognito: tab.isIncognito, select: true)
        }

        tab.onDidFocus = { [weak self, weak tab] in
            guard let self, let id = tab?.id else { return }
            if self.activeTabId != id && !(tab?.isGhost ?? false) {
                self.activeTabId = id
            }
        }
        
        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            tabs.append(tab)
            if select && !isGhost {
                activeTabId = tab.id
            }
        }
        
        ExtensionManager.shared.didOpenTab(tab)
        if select {
            ExtensionManager.shared.didActivateTab(tab)
        }
        enforceMemoryGovernor()
        persistSession()
        
        return tab
    }

    // MARK: - Memory Governor (Tiered Tab Virtualization)
    static let maxActiveWarmTabs = 8

    /// Enforces the concurrency memory governor: preserves active and recent tabs in Hot/Warm tiers
    /// while virtualizing oldest idle background tabs to Cold tier to cap RAM usage.
    func enforceMemoryGovernor() {
        guard tabs.count > Self.maxActiveWarmTabs else { return }
        let inactiveTabs = tabs.filter { $0.id != activeTabId && !$0.isBlank && !$0.isInternalPage }
            .sorted(by: { $0.lastActiveTime > $1.lastActiveTime })
        let demoteCandidates = inactiveTabs.dropFirst(Self.maxActiveWarmTabs - 1)
        for tab in demoteCandidates {
            tab.dehydrateToCold()
        }
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
        AgentPiPManager.shared.landIfTab(id: id)
        if !tab.isGhost && !tab.isIncognito && !tab.isBlank {
            recentlyClosedTabs.insert(ClosedTabSnapshot(url: tab.url, title: tab.title, isIncognito: tab.isIncognito), at: 0)
            if recentlyClosedTabs.count > 25 {
                recentlyClosedTabs.removeLast()
            }
        }
        tab.cleanup()
        ExtensionManager.shared.didCloseTab(id: id)

        // Dissolve any split pair containing this tab and record partner
        var nextActiveFromSplit: UUID? = nil
        if let pairIndex = splitPairs.firstIndex(where: { $0.contains(id) }) {
            let pair = splitPairs.remove(at: pairIndex)
            nextActiveFromSplit = pair.partner(of: id)
        }

        withAnimation(.spring(response: 0.28, dampingFraction: 0.8)) {
            tabs.remove(at: index)
            
            // If the closed tab was active, choose split partner first, else adjacent tab
            if isClosingActive {
                if let partnerId = nextActiveFromSplit, tabs.contains(where: { $0.id == partnerId }) {
                    activeTabId = partnerId
                } else {
                    let visible = visibleTabs
                    if visible.isEmpty {
                        activeTabId = nil
                    } else {
                        let nextIndex = min(index, visible.count - 1)
                        activeTabId = visible[nextIndex].id
                    }
                }
            }
            pruneEmptyGroups()
        }
        persistSession()
    }

    /// Reopens the most recently closed tab (⇧⌘T).
    @discardableResult
    func reopenLastClosedTab() -> Tab? {
        guard !recentlyClosedTabs.isEmpty else { return nil }
        let snapshot = recentlyClosedTabs.removeFirst()
        return newTab(url: snapshot.url, isIncognito: snapshot.isIncognito, select: true)
    }

    /// Selects a tab by ID with smooth content transition.
    func selectTab(id: UUID) {
        if isPickingSplit, let anchor = splitPickAnchor {
            if id != anchor.id, let partner = tabs.first(where: { $0.id == id }) {
                openSplit(partner, beside: anchor, on: splitPickSide.other)
                return
            } else if id == anchor.id {
                commitSplitPickWithNewTab(selectAnchor: true)
                return
            }
        }
        if tabs.contains(where: { $0.id == id }), activeTabId != id {
            captureActiveTabSnapshot()
            withAnimation(.easeInOut(duration: 0.18)) {
                activeTabId = id
            }
            if let tab = tabs.first(where: { $0.id == id }) {
                tab.ensureLoaded()
                tab.hydrateToHot()
                tab.lastActiveTime = Date()
                ExtensionManager.shared.didActivateTab(tab)
            }
            enforceMemoryGovernor()
            persistSession()
        }
    }

    /// Captures an in-memory thumbnail of the active web tab for ⌃Tab quick switcher and zero-flash wake.
    func captureActiveTabSnapshot() {
        guard let current = activeTab, !current.isBlank, !current.isInternalPage else { return }
        current.webView.takeSnapshot(with: nil) { [weak self, weak current] image, _ in
            guard let self = self, let current = current, let image = image else { return }
            Task { @MainActor in
                self.tabSnapshots[current.id] = image
                if self.tabSnapshots.count > 24 {
                    let activeIDs = Set(self.tabs.map(\.id))
                    self.tabSnapshots = self.tabSnapshots.filter { activeIDs.contains($0.key) }
                }
            }
            pruneEmptyGroups()
        }
    }

    /// Most recently used tabs in the active space (for ⌃Tab quick switcher).
    var recentTabsForActiveSpace: [Tab] {
        let activeID = activeSpaceId
        let inSpace = tabs.filter {
            !$0.isGhost && !$0.isBlank && ($0.spaceId == activeID || $0.isPinned)
        }
        return inSpace
            .sorted { $0.lastActiveTime > $1.lastActiveTime }
            .prefix(5)
            .map { $0 }
    }

    func startTabSwitch(backward: Bool = false) {
        let recents = recentTabsForActiveSpace
        guard recents.count > 1 else { return }
        captureActiveTabSnapshot()
        let initialIndex = backward ? recents.count - 1 : 1
        quickSwitcherPickedId = recents[min(initialIndex, recents.count - 1)].id
        isQuickSwitcherVisible = true
    }

    func cycleTabSwitch(forward: Bool = true) {
        let recents = recentTabsForActiveSpace
        guard !recents.isEmpty else { return }
        let currentIndex = recents.firstIndex(where: { $0.id == quickSwitcherPickedId }) ?? 0
        let nextIndex: Int
        if forward {
            nextIndex = (currentIndex + 1) % recents.count
        } else {
            nextIndex = (currentIndex + recents.count - 1) % recents.count
        }
        quickSwitcherPickedId = recents[nextIndex].id
    }

    func finishTabSwitch() {
        guard isQuickSwitcherVisible else { return }
        isQuickSwitcherVisible = false
        if let targetId = quickSwitcherPickedId {
            selectTab(id: targetId)
        }
        quickSwitcherPickedId = nil
    }

    func cancelTabSwitch() {
        isQuickSwitcherVisible = false
        quickSwitcherPickedId = nil
    }

    func pickTabSwitch(id: UUID) {
        quickSwitcherPickedId = id
    }

    /// Opens a link in an Arc-style floating peek preview over the current tab.
    func peek(_ url: URL, from sourceTab: Tab) {
        let page = Tab(initialURL: url, isIncognito: sourceTab.isIncognito)
        page.onRequestPeek = { [weak self, weak page] u in
            guard let self = self, let p = page else { return }
            self.peek(u, from: p)
        }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
            self.peekTab = page
            self.peekFromTabId = sourceTab.id
        }
    }

    /// Dismisses the floating peek preview.
    func closePeek() {
        withAnimation(.easeInOut(duration: 0.16)) {
            self.peekTab = nil
            self.peekFromTabId = nil
        }
    }

    /// Promotes the peek preview to a full tab or split view pane.
    func keepPeek(beside: Bool = false) {
        guard let page = peekTab else { return }
        let fromId = peekFromTabId
        closePeek()
        tabs.append(page)
        if beside, let fromId = fromId, let fromTab = tabs.first(where: { $0.id == fromId }) {
            splitTab(primaryId: fromTab.id, secondaryId: page.id)
        } else {
            selectTab(id: page.id)
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

    /// Focuses the Omnibox address bar to edit the current tab's URL (pre-filling active URL if available).
    func focusAddressBar(prefill: Bool = true) {
        let current = peekTab ?? activeTab
        let hasURL = current?.url != nil && !(current?.isBlank ?? true)
        isEditingCurrentURL = prefill && hasURL
        isAddressBarFocused = true
    }

    /// Opens the Omnibox cleared for creating a new tab (e.g. ⌘T or clicking + New tab).
    func openNewTabOmnibox() {
        isEditingCurrentURL = false
        isAddressBarFocused = true
    }

    /// Opens or switches to the settings internal page (dino://settings).
    func openSettings(section: String? = nil) {
        if let section = section {
            SettingsStore.shared.activeSection = section
        }
        let settingsURL = URL(string: "dino://settings")!
        if let existing = tabs.first(where: { $0.isInternalPage }) {
            selectTab(id: existing.id)
        } else if let current = activeTab, current.isBlank {
            current.load(url: settingsURL)
        } else {
            newTab(url: settingsURL, select: true)
        }
    }

    /// Toggles bookmark state for the specified tab (defaults to active tab).
    func toggleBookmark(for targetTab: Tab? = nil) {
        guard let tab = targetTab ?? activeTab,
              let urlString = tab.url?.absoluteString,
              !tab.isBlank, !tab.isInternalPage, !urlString.isEmpty, urlString != "about:blank" else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if SettingsStore.shared.isBookmarked(urlString) {
                SettingsStore.shared.removeBookmark(url: urlString)
            } else {
                let title = tab.title.isEmpty ? (tab.url?.host ?? urlString) : tab.title
                SettingsStore.shared.addBookmark(title: title, url: urlString)
            }
        }
    }

    /// Opens a bookmark in the current or new tab.
    func openBookmark(_ bookmark: Bookmark) {
        if let destination = URL(string: bookmark.url) {
            if destination.scheme == "dino" && destination.host == "settings" {
                openSettings()
            } else if let current = activeTab, current.isBlank {
                current.load(url: destination)
            } else {
                newTab(url: destination, select: true)
            }
        }
    }

    // MARK: - Split View (Side-by-Side Dual Browsing)

    /// Pairs two tabs side-by-side in Split View.
    func splitTab(primaryId: UUID, secondaryId: UUID, ratio: Double = 0.5) {
        guard primaryId != secondaryId,
              tabs.contains(where: { $0.id == primaryId }),
              tabs.contains(where: { $0.id == secondaryId }) else { return }

        // Dissolve any previous split pairs containing either tab
        splitPairs.removeAll { $0.contains(primaryId) || $0.contains(secondaryId) }

        // Reposition secondary tab immediately adjacent to primary tab in tab list
        if let primIdx = tabs.firstIndex(where: { $0.id == primaryId }),
           let secIdx = tabs.firstIndex(where: { $0.id == secondaryId }) {
            if secIdx != primIdx + 1 {
                let secTab = tabs.remove(at: secIdx)
                let newPrimIdx = tabs.firstIndex(where: { $0.id == primaryId }) ?? primIdx
                tabs.insert(secTab, at: min(tabs.count, newPrimIdx + 1))
            }
        }

        let pair = SplitPair(leftTabId: primaryId, rightTabId: secondaryId, ratio: ratio)
        withAnimation(.easeInOut(duration: 0.22)) {
            splitPairs.append(pair)
            activeTabId = secondaryId
        }
        persistSession()
    }

    /// Toggles split view for current active tab (splits if single, ungroups if already split).
    func toggleSplitCurrentTab() {
        guard let activeId = activeTabId else { return }
        if activeSplitPair != nil {
            closeSplit(for: activeId)
        } else {
            // If there is another open unpinned tab in this space (e.g. GitHub + Settings), pair with it directly
            let otherUnpinned = openTabs.filter { $0.id != activeId }
            if otherUnpinned.count == 1, let partner = otherUnpinned.first {
                splitTab(primaryId: activeId, secondaryId: partner.id)
            } else {
                splitCurrentTab()
            }
        }
    }

    /// Creates a new tab and splits it with the current active tab.
    @discardableResult
    func splitCurrentTab(with url: URL? = nil) -> Tab? {
        guard let currentTab = activeTab else { return nil }
        let newT = newTab(url: url, isIncognito: currentTab.isIncognito, select: false)
        splitTab(primaryId: currentTab.id, secondaryId: newT.id)
        selectTab(id: newT.id)
        return newT
    }

    /// Pairs an agent ghost tab side-by-side with the current active tab for live co-browsing.
    func splitGhostTab(id: UUID, ratio: Double = 0.5) {
        guard let currentTab = activeTab, currentTab.id != id,
              tabs.contains(where: { $0.id == id }) else { return }
        splitTab(primaryId: currentTab.id, secondaryId: id, ratio: ratio)
    }

    /// Promotes an agent background ghost tab to a full visible tab in the human workspace.
    func promoteGhostTab(id: UUID) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isGhost = false
        selectTab(id: tab.id)
        persistSession()
    }

    /// Ungroups the split pair for the given tab, returning both tabs to standalone status (never closes tabs).
    func closeSplit(for tabId: UUID) {
        withAnimation(.easeInOut(duration: 0.22)) {
            splitPairs.removeAll { $0.contains(tabId) }
        }
        activeTabId = tabId
        persistSession()
    }

    /// Swaps the left and right positions in the active split pair.
    func swapSplit(splitPairId: UUID? = nil) {
        let targetId = splitPairId ?? activeSplitPair?.id
        guard let targetId = targetId,
              let idx = splitPairs.firstIndex(where: { $0.id == targetId }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
            splitPairs[idx].swap()
        }
        persistSession()
    }

    /// Updates the split ratio (clamped between 0.2 and 0.8).
    func setSplitRatio(splitPairId: UUID? = nil, ratio: Double) {
        let targetId = splitPairId ?? activeSplitPair?.id
        guard let targetId = targetId,
              let idx = splitPairs.firstIndex(where: { $0.id == targetId }) else { return }
        splitPairs[idx].ratio = min(0.8, max(0.2, ratio.isFinite ? ratio : 0.5))
    }

    /// Returns the split pair containing this tab, if any.
    func split(of tab: Tab) -> SplitPair? {
        splitPairs.first { $0.contains(tab.id) }
    }

    // MARK: - Visual Split Picker

    /// Initiates picking a split beside `tab`. The active tab glides to half width
    /// and the command bar / omnibox opens over the empty half to pick what goes there.
    func pickSplit(beside tab: Tab, on side: SplitSide = .left) {
        selectTab(id: tab.id)
        withAnimation(Theme.glide) {
            splitPickAnchor = tab
            splitPickSide = side
            isAddressBarFocused = true
        }
    }

    /// Cancels split picking and glides the anchor tab back to full width.
    func cancelSplitPick() {
        withAnimation(Theme.glide) {
            splitPickAnchor = nil
            isAddressBarFocused = false
        }
    }

    /// Opens `incoming` beside `anchor` on `side`.
    func openSplit(_ incoming: Tab, beside anchor: Tab, on side: SplitSide = .right) {
        let left = side == .left ? incoming : anchor
        let right = side == .left ? anchor : incoming
        splitTab(primaryId: left.id, secondaryId: right.id)
        withAnimation(Theme.glide) {
            splitPickAnchor = nil
            isAddressBarFocused = false
        }
    }

    /// Commits the active split pick by creating a new blank tab and pairing it in a persistent SplitPair.
    @discardableResult
    func commitSplitPickWithNewTab(selectAnchor: Bool = false) -> Tab? {
        guard let anchor = splitPickAnchor else { return nil }
        let newT = Tab(initialURL: nil, isIncognito: anchor.isIncognito)
        newT.spaceId = activeSpaceId
        tabs.append(newT)
        openSplit(newT, beside: anchor, on: splitPickSide.other)
        if selectAnchor {
            selectTab(id: anchor.id)
        } else {
            selectTab(id: newT.id)
        }
        persistSession()
        return newT
    }

    // MARK: - Window Fullscreen & Menu Bar Glide

    func setFullScreen(_ on: Bool) {
        isFullScreen = on
        if !on {
            menuBarDrop = 0
        }
    }

    func menuBarMoved(to drop: CGFloat, animated: Bool) {
        guard drop != menuBarDrop else { return }
        let glide = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if glide {
            withAnimation(.easeOut(duration: 0.2)) {
                self.menuBarDrop = drop
            }
        } else {
            self.menuBarDrop = drop
        }
    }

    // MARK: - Pinned Tabs & Spaces (Contextual Workspaces)

    /// Toggles the pinned status of a tab.
    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        if tab.place == .basecamp || tab.isPinned {
            removeFromBasecamp(tab: tab)
        } else {
            addToBasecamp(tab: tab)
        }
    }

    /// Switches the active space, bringing its contextual tabs to view.
    func switchSpace(id: UUID) {
        guard spaces.contains(where: { $0.id == id }), activeSpaceId != id else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            activeSpaceId = id
            let spaceTabs = tabs.filter { $0.spaceId == id }
            if let first = spaceTabs.first {
                activeTabId = first.id
            } else {
                activeTabId = nil
            }
        }
    }

    /// Cycles to the next space (or loops around).
    func switchNextSpace() {
        guard spaces.count > 1, let currentIndex = spaces.firstIndex(where: { $0.id == activeSpaceId }) else { return }
        let nextIndex = (currentIndex + 1) % spaces.count
        switchSpace(id: spaces[nextIndex].id)
    }

    /// Switches to the space at the given 0-based index.
    func switchSpace(at index: Int) {
        guard index >= 0 && index < spaces.count else { return }
        switchSpace(id: spaces[index].id)
    }

    /// Creates a new workspace with name, icon, and color.
    func createSpace(name: String, icon: String = "folder.fill", colorHex: String = "#7F9CB0", sharesWithId: UUID? = nil) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleanName.isEmpty ? "New Space" : cleanName
        let newSpace = Space(id: UUID(), name: finalName, icon: icon, colorHex: colorHex, sharesWithId: sharesWithId)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            spaces.append(newSpace)
            switchSpace(id: newSpace.id)
        }
    }

    /// Removes a workspace and reparents its tabs to the first space.
    func deleteSpace(id: UUID) {
        guard spaces.count > 1, let idx = spaces.firstIndex(where: { $0.id == id }) else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            spaces.remove(at: idx)
            let fallbackId = spaces[0].id
            for tab in tabs where tab.spaceId == id {
                tab.spaceId = fallbackId
            }
            if activeSpaceId == id {
                switchSpace(id: fallbackId)
            }
        }
    }
}
