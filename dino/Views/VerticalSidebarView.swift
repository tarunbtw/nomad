//
//  VerticalSidebarView.swift
//  dino
//
//  Firn-style vertical sidebar: traffic lights, sidebar toggle, navigation chevrons,
//  address bar with resting domain, space tabs list with + New tab, and centered space profile switcher.
//

import SwiftUI
import AppKit

struct VerticalSidebarView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore

    @State private var draggingTabId: UUID? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var isSettling: Bool = false
    @State private var isHoveringNewTab: Bool = false
    @State private var isHoveringAddress: Bool = false

    private let tabRowHeight: CGFloat = Theme.rowHeight
    private let tabRowSpacing: CGFloat = Theme.rowSpacing
    private var tabStep: CGFloat { tabRowHeight + tabRowSpacing }

    private var sidebarWidth: CGFloat { CGFloat(settings.sidebarWidth) }

    var body: some View {
        VStack(spacing: 0) {
            // Header: Traffic lights, Sidebar door, Back/Forward
            headerSection
                .padding(.top, store.menuBarDrop)

            // Address bar with domain & reload
            addressBarSection

            // Basecamp Pinned Tiles (if any)
            if !store.basecampTabs.isEmpty {
                BasecampGrid(store: store, sidebarWidth: sidebarWidth)

                Rectangle()
                    .fill(Theme.activeTabHairline)
                    .frame(height: 0.5)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
            }

            // Tabs List for Active Space
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: tabRowSpacing) {
                    // Tab Groups for Active Space
                    ForEach(store.tabGroupsForActiveSpace) { group in
                        TabGroupCardView(store: store, group: group)
                    }

                    // Loose Everyday Tabs & Unified Split Rows
                    let loose = store.looseTabs
                    ForEach(looseTabItems) { item in
                        switch item {
                        case .split(let split, let leftTab, let rightTab):
                            SplitRowView(store: store, split: split, leftTab: leftTab, rightTab: rightTab)
                        case .single(let tab):
                            let isDragging = draggingTabId == tab.id
                            let index = loose.firstIndex(where: { $0.id == tab.id }) ?? 0
                            let offset = tabOffsetY(for: tab, index: index, tabs: loose)

                            VerticalTabRowView(
                                store: store,
                                tab: tab,
                                isActive: tab.id == store.activeTabId,
                                isDragging: isDragging,
                                offsetY: offset,
                                onDragChanged: { translation in
                                    handleDragChanged(tabId: tab.id, translation: translation)
                                },
                                onDragEnded: { translation in
                                    handleDragEnded(tabId: tab.id, translation: translation, tabs: loose)
                                }
                            )
                            .animation(draggingTabId == nil ? nil : (isDragging && !isSettling ? nil : .spring(response: 0.18, dampingFraction: 0.95)), value: offset)
                        }
                    }

                    // + New tab button
                    newTabRow
                }
                .padding(.horizontal, 8)
                .padding(.top, 2)
                .contextMenu {
                    Button("New Tab Group", systemImage: "folder.badge.plus") {
                        store.createTabGroup()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .coordinateSpace(name: "VerticalSidebarSpace")
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Audio & Media Mini-Player Capsule
            MiniPlayer(store: store)

            // Centered Space Profile Row
            footerSection
                .padding(.horizontal, 10)
        }
        .frame(width: sidebarWidth)
        .simultaneousGesture(
            TapGesture().onEnded {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        )
        .background(Theme.frame.ignoresSafeArea())
        .overlay(alignment: .trailing) {
            sidebarResizeHandle
        }
    }

    // MARK: - Header Section
    @ViewBuilder
    private var headerSection: some View {
        HStack(spacing: 2) {
            WindowLights()
                .frame(width: Theme.trafficLightsWidth, height: Theme.rowHeight)

            Door(icon: "sidebar.left", help: "Hide sidebar (⌘S)") {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    settings.toggleSidebarCollapsed()
                }
            }

            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: Theme.rowHeight)

            if let activeTab = store.activeTab {
                SidebarNavButtons(tab: activeTab)
            } else {
                HStack(spacing: 2) {
                    Door(icon: "chevron.left", help: "Back (⌘[)") {}
                        .disabled(true)
                        .opacity(0.35)

                    Door(icon: "chevron.right", help: "Forward (⌘])") {}
                        .disabled(true)
                        .opacity(0.35)
                }
            }
        }
        .frame(height: Theme.rowHeight)
        .padding(.top, Theme.pageInset)
        .padding(.horizontal, 8)
    }

    // MARK: - Address Bar Section
    @ViewBuilder
    private var addressBarSection: some View {
        let isLookout = store.peekTab != nil
        let activeTab = store.peekTab ?? store.activeTab
        let rawSite = WebAddress.site(of: activeTab?.url)
        let displaySite = isLookout ? (rawSite.isEmpty ? "Lookout" : "Lookout: \(rawSite)") : rawSite
        let canBookmark = activeTab != nil && !(activeTab?.isBlank ?? true) && activeTab?.url != nil && !isLookout
        let isBookmarked = activeTab?.url.map { settings.isBookmarked($0.absoluteString) } ?? false

        HStack(spacing: 6) {
            // Text area clicking opens Omnibox
            Button(action: {
                store.focusAddressBar(prefill: true)
            }) {
                HStack(spacing: 0) {
                    Text(displaySite.isEmpty ? "Search or enter address" : displaySite)
                        .font(Theme.tabFont)
                        .foregroundStyle(displaySite.isEmpty ? Theme.faint : Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    if let tab = activeTab, tab.currentZoom != 1.0 {
                        Button {
                            tab.resetZoom()
                        } label: {
                            Text("\(Int(round(tab.currentZoom * 100)))%")
                                .font(Theme.font(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.faint)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help("Reset Zoom (⌘0)")
                    }
                    Spacer(minLength: 4)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if let tab = activeTab {
                // Save / Bookmark button (appears on hover, or stays visible if already bookmarked)
                if (isHoveringAddress || isBookmarked) && canBookmark {
                    Button(action: {
                        store.toggleBookmark(for: tab)
                    }) {
                        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(isBookmarked ? Theme.ink : Theme.muted)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isBookmarked ? "Remove bookmark (⌘D)" : "Bookmark this tab (⌘D)")
                    .transition(.opacity)
                }

                // Reload / Stop button
                Button(action: {
                    if tab.isLoading { tab.stopLoading() } else { tab.reload() }
                }) {
                    Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(tab.isLoading ? "Stop loading" : "Reload this page (⌘R)")
            } else {
                Button(action: {}) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.faint.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(true)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background {
            RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous)
                .fill(isHoveringAddress ? Theme.press : Theme.hover)
                .overlay {
                    if let tab = activeTab {
                        LoadingFrost(
                            isLoading: tab.isLoading,
                            progress: tab.estimatedProgress,
                            spaceColorHex: store.activeSpace.colorHex
                        )
                        .clipShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
                    }
                }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.fieldRadius, style: .continuous))
        .onHover { isHoveringAddress = $0 }
        .animation(.easeOut(duration: 0.15), value: isHoveringAddress)
        .padding(.horizontal, 8)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    // MARK: - New Tab Row
    @ViewBuilder
    private var newTabRow: some View {
        Button(action: {
            if store.isPickingSplit {
                store.commitSplitPickWithNewTab(selectAnchor: false)
            } else {
                store.openNewTabOmnibox()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: "plus")
                    .font(.system(size: 13, weight: .medium))
                Text("New tab")
                    .font(Theme.tabFont)
                Spacer()
            }
            .foregroundStyle(Theme.muted)
            .padding(.horizontal, 10)
            .frame(height: Theme.rowHeight)
            .background(isHoveringNewTab ? Theme.hover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.tabRadius, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHoveringNewTab = $0 }
        .contextMenu {
            Button("New Tab Group", systemImage: "folder.badge.plus") {
                store.createTabGroup()
            }
        }
        .help("New tab (⌘T)")
    }

    // MARK: - Pinned Tabs Section
    @ViewBuilder
    private var pinnedTabsSection: some View {
        let pinned = store.pinnedTabs
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 34, maximum: 44), spacing: 4)], spacing: 4) {
            ForEach(pinned) { tab in
                pinnedSquare(tab: tab, size: 34)
            }
        }
    }

    @ViewBuilder
    private func pinnedSquare(tab: Tab, size: CGFloat) -> some View {
        let isFocused = tab.id == store.activeTabId
        Button(action: { store.selectTab(id: tab.id) }) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isFocused ? Theme.activeTab : Theme.hover)

                if let favicon = tab.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                } else {
                    let letter = tab.title.isEmpty ? (tab.url?.host?.prefix(1).uppercased() ?? "T") : String(tab.title.prefix(1)).uppercased()
                    Text(letter)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(isFocused ? Theme.ink : Theme.muted)
                }
            }
            .frame(width: size, height: size)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tab.title.isEmpty ? (tab.url?.host ?? "Pinned Tab") : tab.title)
        .contextMenu {
            Button("Unpin Tab") {
                store.togglePin(tabId: tab.id)
            }
            Button("Close Tab") {
                store.closeTab(id: tab.id)
            }
        }
    }

    // MARK: - Centered Space Row with Downloads & Overflow Buttons
    @ViewBuilder
    private var footerSection: some View {
        HStack(spacing: 6) {
            SpaceRow(store: store)

            DownloadsButton(store: store)

            OverflowButton(store: store)
        }
        .padding(.bottom, Theme.pageInset)
    }

    // MARK: - Sidebar Resize Handle
    private var sidebarResizeHandle: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: 6)
            .contentShape(Rectangle().inset(by: -3))
            .onHover { hovering in
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let newW = min(360, max(180, settings.sidebarWidth + Double(value.translation.width)))
                        settings.sidebarWidth = newW
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                    settings.sidebarWidth = 240
                }
            }
    }

    // MARK: - Loose Tab Items (Unified Split Rows)
    private enum LooseTabItem: Identifiable {
        case single(Tab)
        case split(SplitPair, Tab, Tab)

        var id: String {
            switch self {
            case .single(let tab): return "single:\(tab.id)"
            case .split(let split, _, _): return "split:\(split.id)"
            }
        }
    }

    private var looseTabItems: [LooseTabItem] {
        var items: [LooseTabItem] = []
        var handled = Set<UUID>()
        let loose = store.looseTabs

        for tab in loose {
            if handled.contains(tab.id) { continue }
            if let pair = store.split(of: tab),
               let leftTab = store.tabs.first(where: { $0.id == pair.leftTabId }),
               let rightTab = store.tabs.first(where: { $0.id == pair.rightTabId }) {
                items.append(.split(pair, leftTab, rightTab))
                handled.insert(pair.leftTabId)
                handled.insert(pair.rightTabId)
            } else {
                items.append(.single(tab))
                handled.insert(tab.id)
            }
        }
        return items
    }

    // MARK: - Drag Reordering
    private func tabOffsetY(for tab: Tab, index: Int, tabs: [Tab]) -> CGFloat {
        guard let draggingId = draggingTabId, draggingId != tab.id,
              let fromIdx = tabs.firstIndex(where: { $0.id == draggingId }) else {
            return tab.id == draggingTabId ? dragOffset : 0
        }
        let currentIndex = index
        let projectedIndex = targetIndex(fromIndex: fromIdx, count: tabs.count)

        if fromIdx < projectedIndex {
            if currentIndex > fromIdx && currentIndex <= projectedIndex {
                return -tabStep
            }
        } else if fromIdx > projectedIndex {
            if currentIndex >= projectedIndex && currentIndex < fromIdx {
                return tabStep
            }
        }
        return 0
    }

    private func targetIndex(fromIndex: Int, count: Int) -> Int {
        let movedSlots = Int(round(dragOffset / tabStep))
        return min(max(fromIndex + movedSlots, 0), count - 1)
    }

    private func handleDragChanged(tabId: UUID, translation: CGFloat) {
        if draggingTabId == nil {
            draggingTabId = tabId
            store.draggingTabId = tabId
            isSettling = false
        }
        dragOffset = translation
    }

    private func handleDragEnded(tabId: UUID, translation: CGFloat, tabs: [Tab]) {
        store.draggingTabId = nil
        guard let fromIdx = tabs.firstIndex(where: { $0.id == tabId }) else {
            draggingTabId = nil
            dragOffset = 0
            return
        }
        let toIdx = targetIndex(fromIndex: fromIdx, count: tabs.count)
        isSettling = true
        withAnimation(.spring(response: 0.22, dampingFraction: 0.85)) {
            dragOffset = CGFloat(toIdx - fromIdx) * tabStep
        }
        if toIdx != fromIdx {
            store.moveTab(from: fromIdx, to: toIdx)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                draggingTabId = nil
                dragOffset = 0
                isSettling = false
            }
        }
    }
}

/// An individual tab row inside the vertical sidebar.
struct VerticalTabRowView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab
    let isActive: Bool
    let isDragging: Bool
    let offsetY: CGFloat
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: (CGFloat) -> Void

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            tabIconView
                .frame(width: 16, height: 16)

            Text(displayTitle)
                .font(.system(size: 13, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? Theme.ink : Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)

            if isHovered {
                Button(action: {
                    store.closeTab(id: tab.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close tab (⌘W)")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.rowHeight)
        .background {
            if isActive {
                ActiveTabBackground()
            } else {
                RoundedRectangle(cornerRadius: Theme.tabRadius, style: .continuous)
                    .fill(isHovered ? Theme.hover : Color.clear)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.tabRadius, style: .continuous))
        .onTapGesture {
            store.selectTab(id: tab.id)
        }
        .offset(y: offsetY)
        .zIndex(isDragging ? 100 : (isActive ? 1 : 0))
        .shadow(color: .black.opacity(isDragging ? 0.16 : 0), radius: 8, y: 2)
        .scaleEffect(isDragging ? 1.02 : 1.0)
        .gesture(
            DragGesture(minimumDistance: 3, coordinateSpace: .named("VerticalSidebarSpace"))
                .onChanged { value in
                    onDragChanged(value.translation.height)
                }
                .onEnded { value in
                    onDragEnded(value.translation.height)
                }
        )
        .onHover { isHovered = $0 }
        .help(displayTitle)
        .contextMenu {
            Button("Reload") {
                tab.reload()
            }
            Button("Duplicate Tab") {
                store.newTab(url: tab.url, isIncognito: tab.isIncognito, select: true)
            }
            Button("Open as Split", systemImage: "rectangle.split.2x1") {
                store.pickSplit(beside: tab)
            }
            Button(tab.place == .basecamp ? "Remove from Basecamp" : "Add to Basecamp") {
                store.togglePin(tabId: tab.id)
            }
            Button("New Group with Tab", systemImage: "folder.badge.plus") {
                store.createTabGroup(spaceId: tab.spaceId, initialTabId: tab.id)
            }
            if !store.tabGroupsForActiveSpace.isEmpty || tab.groupId != nil {
                Menu("Move to Group") {
                    ForEach(store.tabGroupsForActiveSpace) { grp in
                        Button(grp.name) {
                            store.moveTab(tabId: tab.id, toGroupId: grp.id)
                        }
                    }
                    if tab.groupId != nil {
                        Divider()
                        Button("Remove from Group") {
                            store.moveTab(tabId: tab.id, toGroupId: nil)
                        }
                    }
                }
            }
            Button("Tidy Away", systemImage: "archivebox") {
                store.drift(tab: tab)
            }
            Divider()
            Button("Close Tab") {
                store.closeTab(id: tab.id)
            }
        }
    }

    @ViewBuilder
    private var tabIconView: some View {
        if tab.isInternalPage {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11))
                .foregroundStyle(Theme.muted)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: tab.isBlank ? "sparkles" : "globe")
                .font(.system(size: 11))
                .foregroundStyle(isActive ? Theme.ink : Theme.muted)
        }
    }

    private var displayTitle: String {
        if tab.isInternalPage {
            return tab.title
        }
        if tab.isIncognito && (tab.url == nil || tab.isBlank) {
            return "Private Tab"
        }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty && trimmedTitle != "New Tab" {
            return trimmedTitle
        }
        if let host = tab.url?.host, !host.isEmpty, !tab.isBlank {
            return host
        }
        return tab.isBlank ? "New Tab" : (trimmedTitle.isEmpty ? "New Tab" : trimmedTitle)
    }
}

/// Navigation Chevrons directly observing the active Tab for zero-latency enabled/disabled updates.
private struct SidebarNavButtons: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 2) {
            Door(icon: "chevron.left", help: "Back (⌘[)") {
                tab.goBack()
            }
            .disabled(!tab.canGoBack)
            .opacity(tab.canGoBack ? 1.0 : 0.35)

            Door(icon: "chevron.right", help: "Forward (⌘])") {
                tab.goForward()
            }
            .disabled(!tab.canGoForward)
            .opacity(tab.canGoForward ? 1.0 : 0.35)
        }
    }
}

/// The tab on screen: a lifted sheet of frosted glass matching Firn.
private struct ActiveTabBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.tabRadius, style: .continuous)
        shape
            .fill(Theme.activeTab)
            .overlay {
                shape.inset(by: 0.5).strokeBorder(
                    LinearGradient(colors: [Theme.tileRimTop, Theme.tileRimBottom], startPoint: .top, endPoint: .bottom),
                    lineWidth: 0.5
                )
            }
            .overlay {
                shape.strokeBorder(Theme.activeTabHairline, lineWidth: 0.5)
            }
            .shadow(color: Theme.shadowSoft, radius: 1, y: 1)
            .shadow(color: Theme.shadowLift, radius: 4, y: 2)
    }
}
