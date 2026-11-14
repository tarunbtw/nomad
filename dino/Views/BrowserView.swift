//
//  BrowserView.swift
//  dino
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// Main browser window view coordinating the top bar, loading progress, tab stage, and settings.
struct BrowserView: View {
    @ObservedObject var store: BrowserStore
    @StateObject private var settings = SettingsStore.shared
    @ObservedObject private var windowCorners = WindowCorners.shared
    @State private var isCommandPaletteVisible: Bool = false
    @State private var isSidebarPeeking: Bool = false

    var body: some View {
        ZStack(alignment: .leading) {
            // Window Drag & Zoom clearance along top window margin
            VStack {
                WindowDragArea()
                    .frame(height: Theme.pageInset)
                    .frame(maxWidth: .infinity)
                Spacer()
            }
            .zIndex(100)

            // Page Area: floats with pageInset and corner radius beside the sidebar
            let currentSidebarWidth = CGFloat(settings.sidebarWidth)
            let leadingPad = Theme.pageInset + (settings.isSidebarCollapsed ? 0 : currentSidebarWidth)

            Group {
                if store.isPickingSplit, let anchorTab = store.splitPickAnchor {
                    HStack(spacing: Theme.pageInset) {
                        if store.splitPickSide == .left {
                            ZStack {
                                TabStageView(store: store, tab: anchorTab, settings: settings)
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        store.commitSplitPickWithNewTab(selectAnchor: true)
                                    }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous))
                            .frame(maxWidth: .infinity)

                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous)
                                    .fill(Theme.page)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous)
                                            .strokeBorder(Theme.activeTabHairline, lineWidth: 0.5)
                                    }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.commitSplitPickWithNewTab(selectAnchor: false)
                            }
                        } else {
                            ZStack {
                                RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous)
                                    .fill(Theme.page)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous)
                                            .strokeBorder(Theme.activeTabHairline, lineWidth: 0.5)
                                    }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                store.commitSplitPickWithNewTab(selectAnchor: false)
                            }

                            ZStack {
                                TabStageView(store: store, tab: anchorTab, settings: settings)
                                Color.clear
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        store.commitSplitPickWithNewTab(selectAnchor: true)
                                    }
                            }
                            .clipShape(RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous))
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .transition(.opacity)
                } else if let split = store.activeSplitPair,
                   let leftTab = store.tabs.first(where: { $0.id == split.leftTabId }),
                   let rightTab = store.tabs.first(where: { $0.id == split.rightTabId }) {
                    SplitStageView(store: store, split: split, leftTab: leftTab, rightTab: rightTab, settings: settings)
                        .id(split.id)
                } else if let activeTab = store.activeTab {
                    TabStageView(store: store, tab: activeTab, settings: settings)
                        .id(activeTab.id)
                } else {
                    DinoStageScene(spaceColor: store.activeSpace.colorHex)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            store.openNewTabOmnibox()
                        }
                        .transition(.opacity)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Theme.pageCornerRadius, style: .continuous))
            .padding(.top, Theme.pageInset + store.menuBarDrop)
            .padding([.trailing, .bottom], Theme.pageInset)
            .padding(.leading, leadingPad)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: settings.isSidebarCollapsed)
            .animation(.spring(response: 0.24, dampingFraction: 0.88), value: settings.sidebarWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .zIndex(0)

            // Autopilot Rail (if visible)
            if store.isAutopilotRailVisible {
                HStack {
                    Spacer()
                    AutopilotRailView(store: store)
                        .transition(.move(edge: .trailing))
                }
                .zIndex(60)
            }

            // Docked Sidebar
            if !settings.isSidebarCollapsed {
                VerticalSidebarView(store: store, settings: settings)
                    .frame(width: currentSidebarWidth)
                    .transition(.move(edge: .leading))
                    .zIndex(50)
            }

            // Auto-hide hover peek overlay (when sidebar is collapsed)
            if settings.isSidebarCollapsed {
                Color.clear
                    .frame(width: 12)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onHover { hovering in
                        if hovering {
                            withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                isSidebarPeeking = true
                            }
                        }
                    }
                    .zIndex(150)

                if isSidebarPeeking {
                    VerticalSidebarView(store: store, settings: settings)
                        .frame(width: currentSidebarWidth)
                        .shadow(color: Color.black.opacity(0.35), radius: 24, x: 8, y: 0)
                        .transition(.move(edge: .leading))
                        .zIndex(200)
                        .onHover { inside in
                            if !inside {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.88)) {
                                    isSidebarPeeking = false
                                }
                            }
                        }
                }
            }

            if isCommandPaletteVisible {
                CommandPaletteView(store: store, settings: settings, onDismiss: {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                        isCommandPaletteVisible = false
                    }
                })
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .zIndex(300)
            }

            // Modal Centered Floating Omnibox / Command Bar
            if store.isAddressBarFocused {
                OmniboxModalView(store: store, isPresented: $store.isAddressBarFocused)
                    .padding(.leading, leadingPad)
                    .padding([.top, .trailing, .bottom], Theme.pageInset)
                    .zIndex(350)
            }

            // Modal New Space Sheet
            if store.isShowingNewSpaceSheet {
                NewSpaceSheetView(store: store, isPresented: $store.isShowingNewSpaceSheet)
                    .zIndex(360)
            }

            // Modal Arc Import Sheet
            if store.isShowingArcImportModal {
                ArcImportModal(store: store, isPresented: $store.isShowingArcImportModal)
                    .zIndex(362)
            }

            // Modal Extensions Popup (⌘E)
            if store.isShowingExtensionsModal {
                ExtensionsModalView(store: store, isPresented: $store.isShowingExtensionsModal)
                    .zIndex(365)
            }

            // Lookout Link Preview Overlay (Shift-click on links or eye action)
            if let peekTab = store.peekTab {
                LookoutLayer(store: store, settings: settings, tab: peekTab)
                    .transition(.opacity)
                    .zIndex(400)
            }

            // Visual ⌃Tab Quick Switcher Panel
            if store.isQuickSwitcherVisible {
                QuickSwitcherPanel(store: store)
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(450)
            }
        }
        .background(Theme.frame.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(settings.accentColor)
        .onExitCommand {
            if store.isQuickSwitcherVisible {
                store.cancelTabSwitch()
            } else if store.isShowingExtensionsModal {
                store.isShowingExtensionsModal = false
            } else if store.isShowingArcImportModal {
                store.isShowingArcImportModal = false
            } else if store.isShowingNewSpaceSheet {
                store.isShowingNewSpaceSheet = false
            } else if store.isPickingSplit {
                store.cancelSplitPick()
            } else if store.isAddressBarFocused {
                store.isAddressBarFocused = false
            } else if store.peekTab != nil {
                store.closePeek()
            } else if let tab = store.activeTab, tab.isZapperActive {
                tab.stopElementZapper()
            }
        }
        .background {
            QuickSwitchKeyMonitor(store: store)
        }
        .background {
            keyboardShortcutBridge
        }
    }

    @ViewBuilder
    private var keyboardShortcutBridge: some View {
        Group {
            Button("New Tab") { store.openNewTabOmnibox() }.keyboardShortcut("t", modifiers: .command)
            Button("Reopen Closed Tab") { store.reopenLastClosedTab() }.keyboardShortcut("t", modifiers: [.command, .shift])
            Button("New Incognito") { store.newIncognitoTab() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { if let activeId = store.activeTabId { store.closeTab(id: activeId) } }.keyboardShortcut("w", modifiers: .command)
            Button("Address Bar") { store.focusAddressBar(prefill: true) }.keyboardShortcut("l", modifiers: .command)
            Button("Reload") { store.reload() }.keyboardShortcut("r", modifiers: .command)
            Button("Back") { store.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { store.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("Prev Tab") { store.selectPreviousTab() }.keyboardShortcut("{", modifiers: .command)
            Button("Next Tab") { store.selectNextTab() }.keyboardShortcut("}", modifiers: .command)
            Button("Settings") { store.openSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("History") { store.openSettings(section: "History") }.keyboardShortcut("y", modifiers: .command)
            Button("Bookmark") { store.toggleBookmark() }.keyboardShortcut("d", modifiers: .command)
            Button("Extensions") { store.isShowingExtensionsModal.toggle() }.keyboardShortcut("e", modifiers: .command)
            Button("Zoom In") { store.activeTab?.zoomIn() }.keyboardShortcut("+", modifiers: .command)
            Button("Zoom In Eq") { store.activeTab?.zoomIn() }.keyboardShortcut("=", modifiers: .command)
            Button("Zoom Out") { store.activeTab?.zoomOut() }.keyboardShortcut("-", modifiers: .command)
            Button("Zoom Reset") { store.activeTab?.resetZoom() }.keyboardShortcut("0", modifiers: .command)
            Button("Find") { toggleFindBar() }.keyboardShortcut("f", modifiers: .command)
            Button("Print") { store.activeTab?.printPage() }.keyboardShortcut("p", modifiers: .command)
            Button("Dev Drawer") { toggleDevDrawer() }.keyboardShortcut("i", modifiers: [.command, .option])
            Button("Command Palette") { withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) { isCommandPaletteVisible.toggle() } }.keyboardShortcut("k", modifiers: .command)
            Button("Element Zapper") { store.activeTab?.toggleElementZapper() }.keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Reader Mode") { store.activeTab?.toggleReaderMode() }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Picture in Picture") { store.activeTab?.togglePictureInPicture() }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Toggle Split View") {
                if store.activeSplitPair != nil {
                    store.toggleSplitCurrentTab()
                } else if store.isPickingSplit {
                    store.commitSplitPickWithNewTab()
                } else if let active = store.activeTab {
                    store.pickSplit(beside: active)
                }
            }.keyboardShortcut("s", modifiers: [.command, .option])
            Button("Swap Split Panes") { store.swapSplit() }.keyboardShortcut("s", modifiers: [.command, .control])
            Button("Toggle Sidebar Collapse") { settings.toggleSidebarCollapsed() }.keyboardShortcut("s", modifiers: .command)
            Button("Toggle Pin Tab") { if let id = store.activeTabId { store.togglePin(tabId: id) } }.keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next Space") { store.switchNextSpace() }.keyboardShortcut("]", modifiers: [.command, .control])
            Button("Prev Space") { store.switchNextSpace() }.keyboardShortcut("[", modifiers: [.command, .control])
            Button("Space 1") { store.switchSpace(at: 0) }.keyboardShortcut("1", modifiers: .control)
            Button("Space 2") { store.switchSpace(at: 1) }.keyboardShortcut("2", modifiers: .control)
            Button("Space 3") { store.switchSpace(at: 2) }.keyboardShortcut("3", modifiers: .control)
            Button("Toggle Autopilot") {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.86)) {
                    store.isAutopilotRailVisible.toggle()
                }
            }.keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
    }


    private func toggleFindBar() {
        guard let tab = store.activeTab, !tab.isInternalPage && !tab.isBlank else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            tab.isFindBarVisible.toggle()
        }
    }

    private func toggleDevDrawer() {
        guard let tab = store.activeTab, !tab.isInternalPage && !tab.isBlank else { return }
        withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
            tab.isDevDrawerVisible.toggle()
        }
    }
}

/// Stage hosting the active tab: renders native SettingsView for internal pages, WebStage for web URLs, or EmptyStateView for blank tabs.
private struct TabStageView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab
    @ObservedObject var settings: SettingsStore

    var body: some View {
        ZStack {
            if tab.isInternalPage {
                SettingsView(store: store, settings: settings)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .transition(.opacity)
            } else if tab.isBlank {
                // Calm empty start state when tab has no URL loaded
                ZStack {
                    DinoStageScene(spaceColor: store.activeSpace.colorHex)

                    if tab.isIncognito {
                        VStack(spacing: 8) {
                            Image(systemName: "eye.slash.fill")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(Color.purple.opacity(0.85))

                            Text("Private Browsing")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(Theme.ink)

                            Text("Dino does not save your history, cookies, or site data for this tab.")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)
                        }
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    store.openNewTabOmnibox()
                }
                .transition(.opacity)
            } else if tab.isFloatingVideo {
                VStack(spacing: 14) {
                    Image(systemName: "pip.fill")
                        .font(.system(size: 32))
                        .foregroundStyle(settings.accentColor)

                    VStack(spacing: 4) {
                        Text("Video is Playing in Floating Window")
                            .font(.system(size: 15, weight: .semibold))
                        Text("The video continues playing in a borderless window above other apps.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }

                    Button("Return to Tab") {
                        FloatingVideoManager.shared.land()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .tint(settings.accentColor)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
                .transition(.opacity)
            } else {
                VStack(spacing: 0) {
                    if tab.isHitlActive {
                        HitlBannerView(tab: tab)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    // Contextual Chrome Web Store extension installation banner
                    if tab.chromeWebStoreExtensionId != nil {
                        HStack(spacing: 8) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 12))
                                .foregroundStyle(Theme.muted)

                            Text(tab.chromeWebStoreExtensionName ?? "Extension")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)

                            Spacer()

                            WebStoreInstallPill(tab: tab, store: store)
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 38)
                        .background(Theme.page)
                        .overlay(alignment: .bottom) {
                            Rectangle()
                                .fill(Theme.activeTabHairline)
                                .frame(height: 0.5)
                        }
                        .transition(.move(edge: .top).combined(with: .opacity))
                    }

                    ZStack {
                        WebStage(tab: tab)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                        if let snapshot = store.tabSnapshots[tab.id], tab.isLoading {
                            Image(nsImage: snapshot)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .allowsHitTesting(false)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if tab.isDevDrawerVisible {
                        DevDrawerView(tab: tab, store: store)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.24, dampingFraction: 0.88), value: tab.chromeWebStoreExtensionId)
                .animation(.spring(response: 0.26, dampingFraction: 0.86), value: tab.isDevDrawerVisible)
                .animation(.spring(response: 0.24, dampingFraction: 0.88), value: tab.isHitlActive)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Distraction-Free Reading Mode (⌘⇧R)
            if tab.isReaderModeActive, let article = tab.readerArticle {
                ReaderView(article: article, onClose: {
                    tab.toggleReaderMode()
                })
                .transition(.opacity)
                .zIndex(150)
            }

            // Chrome/Arc-style Floating Swipe Gesture Indicator
            if let swipe = tab.swipeState {
                SwipeIndicatorView(swipe: swipe, accentColor: settings.accentColor)
                    .transition(.opacity)
            }

            // Sleek Floating Find in Page Bar (⌘F)
            if tab.isFindBarVisible {
                FindInPageView(tab: tab)
                    .padding(.top, 12)
                    .padding(.trailing, 16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
            }

            // Element Zapper Mode Floating Translucent Capsule Bar (⇧⌘H)
            if tab.isZapperActive {
                ZapperFloatingBar(tab: tab)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity
                    ))
                    .zIndex(200)
            }
            // Sleek Arc/Safari-style Link Hover Bubble
            if let link = tab.hoveredLink, !link.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Text(link)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color(nsColor: .windowBackgroundColor).opacity(0.92), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                            .shadow(color: .black.opacity(0.1), radius: 8, y: 2)
                            .frame(maxWidth: 480, alignment: .leading)
                        Spacer()
                    }
                    .padding(.leading, 12)
                    .padding(.bottom, 8)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
                .zIndex(250)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Dual-pane stage for side-by-side tab browsing with an interactive draggable divider.
private struct SplitStageView: View {
    @ObservedObject var store: BrowserStore
    let split: SplitPair
    @ObservedObject var leftTab: Tab
    @ObservedObject var rightTab: Tab
    @ObservedObject var settings: SettingsStore

    private let dividerWidth: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            let totalW = geo.size.width
            let usableW = max(100, totalW - dividerWidth)
            let leftW = max(120, min(usableW - 120, usableW * CGFloat(split.ratio)))
            let rightW = max(120, usableW - leftW)

            HStack(spacing: 0) {
                // Left Pane
                paneView(for: leftTab, width: leftW)

                // Divider
                SplitDividerView(
                    store: store,
                    split: split,
                    totalWidth: usableW
                )
                .frame(width: dividerWidth)

                // Right Pane
                paneView(for: rightTab, width: rightW)
            }
        }
        .coordinateSpace(name: "SplitStageCoordinateSpace")
    }

    @ViewBuilder
    private func paneView(for tab: Tab, width: CGFloat) -> some View {
        let isFocused = store.activeTabId == tab.id
        ZStack(alignment: .topTrailing) {
            TabStageView(store: store, tab: tab, settings: settings)
                .frame(width: width)

            // Pane Active Highlight
            if isFocused {
                RoundedRectangle(cornerRadius: 0)
                    .strokeBorder(settings.accentColor.opacity(0.35), lineWidth: 1.5)
                    .allowsHitTesting(false)
            }

            // Quick Separate / Ungroup button in top-trailing corner of each pane
            Button(action: {
                store.closeSplit(for: tab.id)
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(5)
                    .background(Color(nsColor: .windowBackgroundColor).opacity(0.85), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 8)
            .help("Separate Tabs (Ungroup)")
        }
        .frame(width: width)
        .clipped()
    }
}

/// Draggable divider between two split view panes with resize cursor, double-click to reset, and context menu.
private struct SplitDividerView: View {
    @ObservedObject var store: BrowserStore
    let split: SplitPair
    let totalWidth: CGFloat

    @State private var isHovered: Bool = false

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            // Hairline separator
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.65))
                .frame(width: 1)

            // Pill Grab Handle
            Capsule()
                .fill(isHovered ? Color.secondary.opacity(0.65) : Color.secondary.opacity(0.25))
                .frame(width: 3.5, height: 28)
                .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onHover { hovering in
            isHovered = hovering
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 1, coordinateSpace: .named("SplitStageCoordinateSpace"))
                .onChanged { value in
                    let newRatio = min(0.8, max(0.2, Double(value.location.x / totalWidth)))
                    store.setSplitRatio(splitPairId: split.id, ratio: newRatio)
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.88)) {
                store.setSplitRatio(splitPairId: split.id, ratio: 0.5)
            }
        }
        .contextMenu {
            Button("Swap Panes") {
                store.swapSplit(splitPairId: split.id)
            }
            Button("Reset to 50 / 50") {
                store.setSplitRatio(splitPairId: split.id, ratio: 0.5)
            }
            Divider()
            Button("Separate Tabs (Ungroup)") {
                store.closeSplit(for: split.leftTabId)
            }
        }
    }
}

/// Sleek floating swipe gesture navigation indicator (inspired by Chrome and Arc).
private struct SwipeIndicatorView: View {
    let swipe: Tab.SwipeGestureState
    let accentColor: Color

    var body: some View {
        HStack {
            if swipe.direction == .forward {
                Spacer()
            }

            ZStack {
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.88))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Circle()
                            .strokeBorder(swipe.isTriggered ? accentColor.opacity(0.85) : Color.primary.opacity(0.12), lineWidth: swipe.isTriggered ? 2 : 1)
                    )
                    .shadow(color: Color.black.opacity(0.18), radius: 8, x: 0, y: 3)

                Image(systemName: swipe.direction == .back ? "chevron.left" : "chevron.right")
                    .font(.system(size: 15, weight: swipe.isTriggered ? .bold : .semibold))
                    .foregroundStyle(swipe.isTriggered ? accentColor : Color.primary)
                    .scaleEffect(swipe.isTriggered ? 1.15 : 1.0)
            }
            .offset(x: swipeOffset)
            .scaleEffect(swipeScale)
            .opacity(swipeOpacity)
            .animation(.interactiveSpring(response: 0.28, dampingFraction: 0.78), value: swipe.distance)
            .animation(.easeInOut(duration: 0.15), value: swipe.isTriggered)

            if swipe.direction == .back {
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }

    private var swipeOffset: CGFloat {
        let maxTravel: CGFloat = 32
        let travel = min(swipe.distance * 0.45, maxTravel)
        return swipe.direction == .back ? travel : -travel
    }

    private var swipeScale: CGFloat {
        let minScale: CGFloat = 0.8
        let scale = minScale + (min(swipe.progress, 1.0) * 0.2)
        return swipe.isTriggered ? scale * 1.08 : scale
    }

    private var swipeOpacity: Double {
        return Double(min(swipe.progress * 1.4, 1.0))
    }
}

/// Sleek floating translucent capsule banner for Element Zapper mode (⇧⌘H)
private struct ZapperFloatingBar: View {
    @ObservedObject var tab: Tab
    @ObservedObject var zapperStore = ZapperStore.shared
    @State private var isDoneHovered: Bool = false
    @State private var isUnhideHovered: Bool = false

    var body: some View {
        let host = tab.url?.host ?? ""
        let zappedCount = zapperStore.count(for: host)

        HStack(spacing: 10) {
            // Accent icon badge
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.16))
                    .frame(width: 20, height: 20)
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.red)
            }

            // Description text
            HStack(spacing: 5) {
                Text("Element Zapper")
                    .font(.system(size: 11.5, weight: .semibold))
                Text("— Click elements to hide")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // Hidden count & Unhide All button
            if zappedCount > 0 {
                HStack(spacing: 4) {
                    Text("\(zappedCount)")
                        .font(.system(size: 10.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text("hidden")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(Capsule().fill(Color.primary.opacity(0.08)))

                Button(action: {
                    tab.unhideAllZappedElements()
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .semibold))
                        Text("Unhide All")
                            .font(.system(size: 10.5, weight: .medium))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .fill(isUnhideHovered ? Color.primary.opacity(0.14) : Color.primary.opacity(0.08))
                    )
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .systemCursor(.pointingHand)
                .onHover { isUnhideHovered = $0 }
            }

            Divider()
                .frame(height: 14)
                .opacity(0.25)

            // Done Button (Custom capsule pill, comfortable vertical padding, never chopped)
            Button(action: {
                tab.stopElementZapper()
            }) {
                HStack(spacing: 4) {
                    Text("Done")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Esc")
                        .font(.system(size: 9.5, weight: .medium))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.white.opacity(0.25)))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(
                    Capsule()
                        .fill(isDoneHovered ? Color.red.opacity(0.95) : Color.red.opacity(0.85))
                        .shadow(color: Color.red.opacity(0.35), radius: 4, y: 1.5)
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .systemCursor(.pointingHand)
            .keyboardShortcut(.escape, modifiers: [])
            .onHover { isDoneHovered = $0 }
        }
        .padding(.leading, 10)
        .padding(.trailing, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.22), radius: 14, x: 0, y: 6)
                .shadow(color: .black.opacity(0.10), radius: 3, x: 0, y: 1)
        )
        .overlay(
            Capsule()
                .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
        )
        .systemCursor(.arrow)
    }
}

/// AppKit cursor rect provider for SwiftUI views on macOS.
private struct CursorRectView: NSViewRepresentable {
    let cursor: NSCursor

    func makeNSView(context: Context) -> CursorNSView {
        let view = CursorNSView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorNSView, context: Context) {
        if nsView.cursor !== cursor {
            nsView.cursor = cursor
            nsView.window?.invalidateCursorRects(for: nsView)
        }
    }
}

private final class CursorNSView: NSView {
    var cursor: NSCursor = .arrow

    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: cursor)
    }
}

private extension View {
    func systemCursor(_ cursor: NSCursor) -> some View {
        background(CursorRectView(cursor: cursor))
    }
}



