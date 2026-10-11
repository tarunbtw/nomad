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

    var body: some View {
        VStack(spacing: 0) {
            // Top browser chrome (includes bottom progress bar overlay)
            TopBarView(store: store, settings: settings)

            // Tab Stage (observes activeTab directly so isBlank/isInternalPage changes trigger immediate redraws)
            if let activeTab = store.activeTab {
                TabStageView(store: store, tab: activeTab, settings: settings)
                    .id(activeTab.id)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .background {
            // Native keyboard shortcuts
            Group {
                Button("") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("") {
                    if let activeId = store.activeTabId { store.closeTab(id: activeId) }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("") { store.isAddressBarFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                Button("") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { store.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { store.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { store.selectPreviousTab() }
                    .keyboardShortcut("{", modifiers: .command)
                Button("") { store.selectNextTab() }
                    .keyboardShortcut("}", modifiers: .command)
                Button("") { store.openSettings() }
                    .keyboardShortcut(",", modifiers: .command)
                Button("") {
                    if let tab = store.activeTab,
                       let urlString = tab.url?.absoluteString,
                       !tab.isBlank, !tab.isInternalPage, !urlString.isEmpty, urlString != "about:blank" {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            if settings.isBookmarked(urlString) {
                                settings.removeBookmark(url: urlString)
                            } else {
                                let title = tab.title.isEmpty ? (tab.url?.host ?? urlString) : tab.title
                                settings.addBookmark(title: title, url: urlString)
                            }
                        }
                    }
                }
                .keyboardShortcut("d", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
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
                if tab.url?.host == "tune" {
                    TuneView(store: store, settings: settings)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                } else {
                    SettingsView(store: store, settings: settings)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                }
            } else if tab.isBlank {
                // Calm empty start state when tab has no URL loaded
                EmptyStateView(tab: tab, store: store, settings: settings)
                    .transition(.opacity)
            } else {
                WebStage(tab: tab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

            // Tap on background focuses the search field
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused = true
                }

            // Centered omnibox and quick bookmarks
            VStack(spacing: 16) {
                // Centered "Enter a web address" field
                HStack(spacing: 8) {
                    TextField("Enter a web address", text: $text)
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
                    Button(action: { store.openTune() }) {
                        Image(systemName: "pencil")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                            .padding(10)
                            .background(Color.primary.opacity(0.05), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Tune (nomad://tune)")
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
        switch settings.backgroundStyle {
        case "hex":
            settings.customBgColor
        case "customImage":
            if !settings.customBgPath.isEmpty,
               FileManager.default.fileExists(atPath: settings.customBgPath),
               let nsImage = NSImage(contentsOfFile: settings.customBgPath) {
                GeometryReader { geo in
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
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
        if !trimmed.isEmpty {
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
        nsView.isVibrant = isVibrant
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

