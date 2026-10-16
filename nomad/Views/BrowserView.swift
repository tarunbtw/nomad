//
//  BrowserView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// Main browser window view coordinating the top bar, loading progress, tab stage, and settings.
struct BrowserView: View {
    @ObservedObject var store: BrowserStore
    @StateObject private var settings = SettingsStore.shared
    @State private var isCommandPaletteVisible: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                // Top browser chrome (includes bottom progress bar overlay)
                TopBarView(store: store, settings: settings)
                    .frame(height: 50)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .zIndex(100)

                // Tab Stage (observes activeTab directly with silky crossfade animation)
                if let activeTab = store.activeTab {
                    TabStageView(store: store, tab: activeTab, settings: settings)
                        .id(activeTab.id)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                        .zIndex(0)
                } else {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        }
        .background {
            if settings.isVibrant {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                    .ignoresSafeArea()
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .ignoresSafeArea()
            }
        }
        .background(WindowVibrancyController(isVibrant: settings.isVibrant))
        .preferredColorScheme(settings.colorScheme)
        .tint(settings.accentColor)
        .onExitCommand {
            if let tab = store.activeTab, tab.isZapperActive {
                tab.stopElementZapper()
            }
        }
        .background {
            keyboardShortcutBridge
        }
    }

    @ViewBuilder
    private var keyboardShortcutBridge: some View {
        Group {
            Button("New Tab") { store.newTab() }.keyboardShortcut("t", modifiers: .command)
            Button("New Incognito") { store.newIncognitoTab() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Close Tab") { if let activeId = store.activeTabId { store.closeTab(id: activeId) } }.keyboardShortcut("w", modifiers: .command)
            Button("Address Bar") { store.isAddressBarFocused = true }.keyboardShortcut("l", modifiers: .command)
            Button("Reload") { store.reload() }.keyboardShortcut("r", modifiers: .command)
            Button("Back") { store.goBack() }.keyboardShortcut("[", modifiers: .command)
            Button("Forward") { store.goForward() }.keyboardShortcut("]", modifiers: .command)
            Button("Prev Tab") { store.selectPreviousTab() }.keyboardShortcut("{", modifiers: .command)
            Button("Next Tab") { store.selectNextTab() }.keyboardShortcut("}", modifiers: .command)
            Button("Settings") { store.openSettings() }.keyboardShortcut(",", modifiers: .command)
            Button("History") { store.openSettings(section: "History") }.keyboardShortcut("y", modifiers: .command)
            Button("Bookmark") { toggleBookmark() }.keyboardShortcut("d", modifiers: .command)
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
        }
        .opacity(0)
        .allowsHitTesting(false)
    }

    private func toggleBookmark() {
        guard let tab = store.activeTab,
              let urlString = tab.url?.absoluteString,
              !tab.isBlank, !tab.isInternalPage, !urlString.isEmpty, urlString != "about:blank" else { return }
        withAnimation(.easeInOut(duration: 0.15)) {
            if settings.isBookmarked(urlString) {
                settings.removeBookmark(url: urlString)
            } else {
                let title = tab.title.isEmpty ? (tab.url?.host ?? urlString) : tab.title
                settings.addBookmark(title: title, url: urlString)
            }
        }
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
                EmptyStateView(tab: tab, store: store, settings: settings)
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
                    WebStage(tab: tab)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    if tab.isDevDrawerVisible {
                        DevDrawerView(tab: tab, store: store)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.spring(response: 0.26, dampingFraction: 0.86), value: tab.isDevDrawerVisible)
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Minimal start canvas for blank tabs: clean centered URL input field, quick bookmarks, and custom atmosphere.
private struct EmptyStateView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            // Atmosphere Canvas (Theme Solid, Custom Hex, or Custom Image)
            atmosphereView

            // Centered omnibox and quick bookmarks
            VStack(spacing: 16) {
                // Incognito Private Browsing Badge & Notice
                if tab.isIncognito {
                    VStack(spacing: 8) {
                        Image(systemName: "eye.slash.fill")
                            .font(.system(size: 32, weight: .semibold))
                            .foregroundStyle(Color.purple.opacity(0.85))

                        Text("Private Browsing")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("Nomad does not save your history, cookies, or site data for this tab.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.bottom, 6)
                }

                // Centered "Enter a web address" field
                HStack(spacing: 8) {
                    TextField(tab.isIncognito ? "Search privately or enter address" : "Enter a web address", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14.5, weight: .regular))
                        .foregroundStyle(.primary)
                        .focused($isFocused)
                        .onSubmit {
                            submit()
                        }

                    if !text.isEmpty {
                        Button(action: { text = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .frame(width: 480, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(nsColor: .controlBackgroundColor).opacity(0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(isFocused ? settings.accentColor.opacity(0.5) : Color.primary.opacity(0.12), lineWidth: 1)
                )
                .overlay(alignment: .top) {
                    // Floating autocomplete suggestions dropdown directly beneath the field without jumping layout
                    if isFocused && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        OmniboxSuggestionsView(query: text, width: 480) { url in
                            tab.load(url: url)
                        }
                        .offset(y: 46)
                        .zIndex(100)
                    }
                }

                // Quick Bookmarks row below the field
                if !settings.bookmarks.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(settings.bookmarks.prefix(6)) { bookmark in
                            Button(action: { store.openBookmark(bookmark) }) {
                                HStack(spacing: 5) {
                                    Image(systemName: "bookmark.fill")
                                        .font(.system(size: 9))
                                        .foregroundStyle(settings.accentColor)
                                    Text(bookmark.title)
                                        .font(.system(size: 11, weight: .regular))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Color.primary.opacity(0.04), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 4)
                }
            }

            // Bottom-right Customize / Tune Canvas icon button
            VStack {
                Spacer()
                HStack {
                    Spacer()
                    Button(action: { store.openSettings(section: "General") }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Customize Appearance (nomad://settings, ⌘,)")
                    .padding(20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .onChange(of: store.isAddressBarFocused) { _, focused in
            if focused {
                isFocused = true
                store.isAddressBarFocused = false
            }
        }
    }

    @ViewBuilder
    private var atmosphereView: some View {
        Group {
            switch settings.backgroundStyle {
            case "hex":
                settings.customBgColor
            case "customImage":
                if let nsImage = settings.cachedCustomBgImage {
                    GeometryReader { geo in
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                            .overlay(Color.black.opacity(0.35))
                    }
                } else {
                    themeSolidBackground
                }
            default:
                themeSolidBackground
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var themeSolidBackground: some View {
        if settings.isVibrant {
            Color(nsColor: .windowBackgroundColor).opacity(0.15)
        } else {
            Color(nsColor: .windowBackgroundColor)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let parsed = URLParser.parse(trimmed)
        if parsed.scheme == "nomad" && (parsed.host == "settings" || parsed.host == "tune") {
            store.openSettings()
        } else {
            tab.load(text: trimmed)
        }
    }
}

// MARK: - AppKit Window Vibrancy & Visual Effects

/// Native AppKit visual effect view providing blurred vibrancy behind windows.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .underWindowBackground
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let effectView = NSVisualEffectView()
        effectView.material = material
        effectView.blendingMode = blendingMode
        effectView.state = .active
        return effectView
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

/// Dynamic window vibrancy coordinator updating NSWindow opacity and background color.
struct WindowVibrancyController: NSViewRepresentable {
    let isVibrant: Bool

    func makeNSView(context: Context) -> ConfigNSView {
        let view = ConfigNSView()
        view.isVibrant = isVibrant
        return view
    }

    func updateNSView(_ nsView: ConfigNSView, context: Context) {
        if nsView.isVibrant != isVibrant {
            nsView.isVibrant = isVibrant
        }
    }
}

final class ConfigNSView: NSView {
    var isVibrant: Bool = false {
        didSet {
            apply()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        apply()
    }

    private func apply() {
        guard let window = window else { return }
        window.titlebarAppearsTransparent = true
        if isVibrant {
            window.isOpaque = false
            window.backgroundColor = .clear
        } else {
            window.isOpaque = true
            window.backgroundColor = .windowBackgroundColor
        }
        window.invalidateShadow()
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

