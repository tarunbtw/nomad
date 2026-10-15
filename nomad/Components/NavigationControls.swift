//
//  NavigationControls.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Minimal navigation control buttons: Back, Forward, Reload, Bookmark, Settings.
struct NavigationControls: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore = SettingsStore.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    @State private var isShowingExtensionsMenu: Bool = false
    @State private var isShowingDownloadsMenu: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { tab.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tab.canGoBack)
            .opacity(tab.canGoBack ? 1.0 : 0.35)
            .help("Back (⌘[)")

            Button(action: { tab.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tab.canGoForward)
            .opacity(tab.canGoForward ? 1.0 : 0.35)
            .help("Forward (⌘])")

            Button(action: {
                if tab.isLoading {
                    tab.stopLoading()
                } else {
                    tab.reload()
                }
            }) {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.isLoading ? "Stop Loading" : "Reload (⌘R)")

            // 1-Click Chrome Web Store install button when visiting an extension page
            WebStoreInstallPill(tab: tab, store: store)

            // Pinned WebExtension action buttons (e.g. uBlock Origin Lite)
            ExtensionActionBar(store: store)

            // Extensions Menu button (Puzzle icon)
            Button(action: { isShowingExtensionsMenu.toggle() }) {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isShowingExtensionsMenu ? settings.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(ExtensionAnchor(id: "extensions_menu_anchor"))
            .help("Extensions")
            .popover(isPresented: $isShowingExtensionsMenu, arrowEdge: .bottom) {
                ExtensionsMenuPopover(tab: tab, store: store, isPresented: $isShowingExtensionsMenu)
            }

            // Downloads Button (appears when downloads are active or completed)
            if !downloadManager.downloads.isEmpty {
                Button(action: { isShowingDownloadsMenu.toggle() }) {
                    ZStack {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(downloadManager.hasActiveDownloads ? settings.accentColor : Color.primary)

                        if downloadManager.hasActiveDownloads {
                            Circle()
                                .trim(from: 0, to: downloadManager.overallProgress)
                                .stroke(settings.accentColor, lineWidth: 1.5)
                                .frame(width: 16, height: 16)
                                .rotationEffect(.degrees(-90))
                        }
                    }
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Downloads")
                .popover(isPresented: $isShowingDownloadsMenu, arrowEdge: .bottom) {
                    DownloadsMenuPopover(store: store, isPresented: $isShowingDownloadsMenu)
                }
            }

            let urlString = tab.url?.absoluteString ?? ""
            let canBookmark = !tab.isBlank && !tab.isInternalPage && !urlString.isEmpty && urlString != "about:blank"
            let isBookmarked = canBookmark && settings.isBookmarked(urlString)

            Button(action: {
                guard canBookmark else { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if isBookmarked {
                        settings.removeBookmark(url: urlString)
                    } else {
                        let title = tab.title.isEmpty ? (tab.url?.host ?? urlString) : tab.title
                        settings.addBookmark(title: title, url: urlString)
                    }
                }
            }) {
                Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isBookmarked ? settings.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canBookmark)
            .opacity(canBookmark ? 1.0 : 0.35)
            .help(isBookmarked ? "Remove Bookmark (⌘D)" : "Bookmark Tab (⌘D)")

            let canInspect = !tab.isBlank && !tab.isInternalPage


            Button(action: {
                guard canInspect else { return }
                withAnimation(.spring(response: 0.28, dampingFraction: 0.85)) {
                    tab.isDevDrawerVisible.toggle()
                }
            }) {
                Image(systemName: tab.isDevDrawerVisible ? "curlybraces.square.fill" : "curlybraces")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tab.isDevDrawerVisible ? settings.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canInspect)
            .opacity(canInspect ? 1.0 : 0.35)
            .help("Developer Tools (⌘⌥I)")

            let isSettingsActive = tab.isInternalPage || tab.url?.scheme == "nomad" || tab.url?.host == "settings"

            Button(action: { store.openSettings() }) {
                Image(systemName: isSettingsActive ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSettingsActive ? settings.accentColor : Color.primary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Settings (nomad://settings, ⌘,)")
        }
        .foregroundStyle(.primary)
    }
}

