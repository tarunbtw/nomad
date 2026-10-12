//
//  SettingsView.swift
//  nomad
//
//  Created by tarun on 11/10/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Native developer-style Settings page (nomad://settings).
/// Focuses on browser configuration: Bookmarks, General preferences, and WebExtensions.
struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore

    private var selectedSection: Section {
        get { Section(rawValue: settings.activeSection) ?? .general }
        nonmutating set { settings.activeSection = newValue.rawValue }
    }
    @State private var importStatusMessage: String? = nil
    @ObservedObject private var extensionManager = ExtensionManager.shared
    @ObservedObject private var historyStore = HistoryStore.shared
    @State private var historySearchQuery: String = ""
    @State private var showingClearHistoryAlert: Bool = false
    @State private var hoveredHistoryId: UUID? = nil
    @State private var webStoreInput: String = ""
    @State private var extensionErrorMessage: String? = nil
    @State private var isInstallingExtension: Bool = false

    enum Section: String, CaseIterable, Identifiable {
        case general = "General"
        case history = "History"
        case bookmarks = "Bookmarks"
        case downloads = "Downloads"
        case extensions = "Extensions"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .history: return "clock.arrow.circlepath"
            case .bookmarks: return "bookmark"
            case .downloads: return "arrow.down.circle"
            case .extensions: return "puzzlepiece.extension"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Left Navigation Rail
            sidebarRail
                .frame(width: 180)
                .background(Color.primary.opacity(0.02))

            Divider().opacity(0.15)

            // Right Main Content
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 28) {
                    switch selectedSection {
                    case .general:
                        generalSection
                    case .history:
                        historySection
                    case .bookmarks:
                        bookmarksSection
                    case .downloads:
                        downloadsSection
                    case .extensions:
                        extensionsSection
                    }
                }
                .padding(32)
                .frame(maxWidth: 680, alignment: .leading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            settings.isVibrant
                ? Color(nsColor: .windowBackgroundColor).opacity(0.4)
                : Color(nsColor: .windowBackgroundColor)
        )
    }

    // MARK: - Sidebar Rail
    private var sidebarRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.primary)
                .padding(.horizontal, 16)
                .padding(.top, 24)
                .padding(.bottom, 12)

            ForEach(Section.allCases) { section in
                Button(action: { selectedSection = section }) {
                    HStack(spacing: 10) {
                        Image(systemName: section.icon)
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 16)
                        Text(section.rawValue)
                            .font(.system(size: 13, weight: selectedSection == section ? .medium : .regular))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .foregroundStyle(selectedSection == section ? .primary : .secondary)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedSection == section ? Color.primary.opacity(0.08) : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
            }

            Divider().opacity(0.12).padding(.horizontal, 14).padding(.vertical, 6)

            // Direct link to Canvas Tuning (nomad://tune)
            Button(action: { store.openTune() }) {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                    Text("Tune")
                        .font(.system(size: 13))
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(.secondary)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.clear))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 10)
            .help("Customize Start Canvas wallpaper & theme (nomad://tune)")

            Spacer()

            Text("nomad://settings")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(16)
        }
    }

    // MARK: - Bookmarks Section
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Bookmarks Heading with Import Button on the right
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Bookmarks")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Manage saved links or import existing bookmarks from Chrome, Firefox, or Safari.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: importBookmarksFromFile) {
                    HStack(spacing: 6) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Text("Import")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Import bookmarks from Chrome, Firefox, or Safari (HTML or JSON)")
            }

            // Optional import feedback status banner
            if let status = importStatusMessage {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(settings.accentColor)
                        .font(.system(size: 13))
                    Text(status)
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                    Button(action: { withAnimation { importStatusMessage = nil } }) {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(settings.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .transition(.opacity)
            }

            // Bookmarks List
            card(title: "Saved Bookmarks (\(settings.bookmarks.count))") {
                if settings.bookmarks.isEmpty {
                    Text("No bookmarks saved yet. Save pages using the bookmark icon in the top bar or import from another browser.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 0) {
                        ForEach(settings.bookmarks) { bookmark in
                            HStack {
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(settings.accentColor)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(bookmark.title)
                                        .font(.system(size: 13, weight: .medium))
                                    Text(bookmark.url)
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button("Open") {
                                    store.openBookmark(bookmark)
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(settings.accentColor)
                                .padding(.horizontal, 8)

                                Button(action: { settings.removeBookmark(id: bookmark.id) }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.tertiary)
                                }
                                .buttonStyle(.plain)
                                .help("Delete bookmark")
                            }
                            .padding(.vertical, 8)

                            if bookmark.id != settings.bookmarks.last?.id {
                                Divider().opacity(0.1)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Downloads Section
    @ObservedObject private var downloadManager = DownloadManager.shared

    private var downloadsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "Downloads", subtitle: "Manage downloaded files, locations, and download history.")

            // Downloads Location & Action Card
            card(title: "Downloads Location") {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(downloadManager.displayPath)
                            .font(.system(size: 13, weight: .medium, design: .monospaced))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Text("Files downloaded from the web are saved here with macOS quarantine security tags.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open in Finder") {
                        downloadManager.openDownloadsFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Downloads List Card
            card(title: "Recent Downloads (\(downloadManager.downloads.count))") {
                if downloadManager.downloads.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "arrow.down.circle")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary.opacity(0.5))
                            .padding(.top, 8)
                        Text("No downloaded files yet.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                } else {
                    VStack(spacing: 0) {
                        HStack {
                            Spacer()
                            Button("Clear All") {
                                downloadManager.clearCompleted()
                            }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .buttonStyle(.plain)
                        }
                        .padding(.bottom, 8)

                        ForEach(downloadManager.downloads) { item in
                            downloadSettingsRow(item: item)
                            if item.id != downloadManager.downloads.last?.id {
                                Divider().opacity(0.1).padding(.vertical, 6)
                            }
                        }
                    }
                }
            }
        }
    }

    private func downloadSettingsRow(item: DownloadItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: downloadFileIcon(for: item.suggestedFilename))
                .font(.system(size: 20))
                .foregroundStyle(downloadIconColor(for: item.state))
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.suggestedFilename)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(item.state.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(downloadIconColor(for: item.state))

                    if !item.formattedSize.isEmpty {
                        Text("•")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                        Text(item.formattedSize)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    if let err = item.errorMessage {
                        Text("— \(err)")
                            .font(.system(size: 10))
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
            }

            Spacer()

            if item.state == .downloading {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .frame(width: 80)

                Button(action: { item.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if item.state == .completed {
                Button("Open") {
                    downloadManager.openFile(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button("Finder") {
                    downloadManager.showInFinder(item)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Button(action: { downloadManager.removeDownload(item) }) {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Remove from history")
        }
        .padding(.vertical, 4)
    }

    private func downloadFileIcon(for filename: String) -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "dmg", "pkg": return "shippingbox.fill"
        case "zip", "tar", "gz", "rar": return "doc.zipper"
        case "pdf": return "doc.richtext"
        case "png", "jpg", "jpeg", "webp", "gif": return "photo"
        case "mp4", "mov", "webm": return "film"
        case "mp3", "wav", "m4a": return "music.note"
        default: return "doc.fill"
        }
    }

    private func downloadIconColor(for state: DownloadItem.DownloadState) -> Color {
        switch state {
        case .downloading: return .blue
        case .completed: return .green
        case .failed: return .red
        case .cancelled: return .secondary
        }
    }

    // MARK: - General Section
    private var generalSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "General", subtitle: "Configure defaults, search engines, and browser behavior.")

            card(title: "Default Search Engine") {
                Picker("Search Engine", selection: $settings.searchEngine) {
                    Text("DuckDuckGo (Privacy)").tag("duckduckgo")
                    Text("Google").tag("google")
                    Text("Kagi").tag("kagi")
                    Text("Bing").tag("bing")
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 260)
            }

            card(title: "Privacy & Data") {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Browsing History")
                                .font(.system(size: 13, weight: .medium))
                            Text("\(historyStore.items.count) visited sites logged locally.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage History") {
                            selectedSection = .history
                        }
                        .buttonStyle(.bordered)
                    }

                    Divider().opacity(0.15)

                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Downloads List")
                                .font(.system(size: 13, weight: .medium))
                            Text("Clear recent download history without deleting files.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Manage Downloads") {
                            selectedSection = .downloads
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    // MARK: - History Section
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            // History Header & Clear Action
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("History")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Sites you've visited across tabs and browsing sessions.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !historyStore.items.isEmpty {
                    Button(action: { showingClearHistoryAlert = true }) {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Clear History")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .confirmationDialog("Clear Browsing History?", isPresented: $showingClearHistoryAlert, titleVisibility: .visible) {
                        Button("Clear All History", role: .destructive) {
                            historyStore.clear()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will remove all \(historyStore.items.count) visited pages from local history.")
                    }
                }
            }

            // Search Bar
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                TextField("Search history by title or domain...", text: $historySearchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))

                if !historySearchQuery.isEmpty {
                    Button(action: { historySearchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            )

            // Date Groups List
            let groups = historyStore.grouped(matching: historySearchQuery)

            if groups.isEmpty {
                emptyHistoryView
            } else {
                LazyVStack(alignment: .leading, spacing: 20) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 10) {
                            // Date Section Header
                            HStack {
                                Text(group.title)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.primary)

                                Spacer()

                                Text("\(group.items.count) visit\(group.items.count == 1 ? "" : "s")")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 2)

                            // Group Items Container Card
                            VStack(spacing: 0) {
                                ForEach(group.items) { item in
                                    historyRow(item: item)
                                    if item.id != group.items.last?.id {
                                        Divider().opacity(0.08)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.primary.opacity(0.03))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                    }
                }
            }
        }
    }

    private func historyRow(item: HistoryItem) -> some View {
        HStack(spacing: 12) {
            // Localized Time (e.g. 18:30)
            Text(formattedTime(for: item.timestamp))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .leading)

            // Favicon or Globe
            if let cached = FaviconService.shared.cachedFavicon(for: item.host) {
                Image(nsImage: cached)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: "globe")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
            }

            // Title & Domain
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text(item.host.isEmpty ? item.url : item.host)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Open Action
            Button("Open") {
                if let url = URL(string: item.url) {
                    store.newTab(url: url, select: true)
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(settings.accentColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color.primary.opacity(hoveredHistoryId == item.id ? 0.06 : 0.0), in: RoundedRectangle(cornerRadius: 4))

            // Delete Visit Record Action
            Button(action: {
                withAnimation(.easeInOut(duration: 0.15)) {
                    historyStore.removeItem(id: item.id)
                }
            }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove from history")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { isHovered in
            if isHovered {
                hoveredHistoryId = item.id
            } else if hoveredHistoryId == item.id {
                hoveredHistoryId = nil
            }
        }
        .contextMenu {
            Button("Open in New Tab") {
                if let url = URL(string: item.url) {
                    store.newTab(url: url, select: true)
                }
            }
            Button("Copy Link Address") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.url, forType: .string)
            }
            Divider()
            Button("Delete from History", role: .destructive) {
                historyStore.removeItem(id: item.id)
            }
        }
    }

    private func formattedTime(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private var emptyHistoryView: some View {
        VStack(spacing: 12) {
            Image(systemName: historySearchQuery.isEmpty ? "clock.arrow.circlepath" : "magnifyingglass")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
                .padding(.top, 24)

            Text(historySearchQuery.isEmpty ? "No Browsing History" : "No Matching Results")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.secondary)

            Text(
                historySearchQuery.isEmpty
                    ? "Websites you visit in regular browsing will appear here, grouped by date."
                    : "No visits matched \"\(historySearchQuery)\". Try searching by another keyword or host."
            )
            .font(.system(size: 12))
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 360)
            .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.02))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    // MARK: - Extensions Section
    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "Extensions", subtitle: "Install Chrome Web Store extensions or load unpacked developer extensions.")

            // Add from Chrome Web Store Card
            card(title: "Add from Chrome Web Store") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        TextField("Paste Chrome Web Store URL or 32-letter ID", text: $webStoreInput)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12))
                            .onSubmit { installFromWebStore() }

                        Button(action: { installFromWebStore() }) {
                            if isInstallingExtension {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 60)
                            } else {
                                Text("Install")
                                    .frame(width: 60)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isInstallingExtension || webStoreInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Open Store") {
                            let storeURL = URL(string: "https://chromewebstore.google.com")!
                            store.newTab(url: storeURL, select: true)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let errorMessage = extensionErrorMessage {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                            Text(errorMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                        }
                    } else {
                        Text("Supports Chrome extensions built with Manifest V2 and V3, running directly on WebKit.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            // Developer Mode / Unpacked Card
            card(title: "Developer Mode (Unpacked)") {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Load Unpacked Extension")
                            .font(.system(size: 12, weight: .medium))
                        Text("Select a local directory containing manifest.json for testing and development.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button("Choose Folder…") {
                        loadUnpackedFolder()
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Installed Extensions List Card
            card(title: "Installed Extensions (\(extensionManager.installed.count))") {
                if extensionManager.installed.isEmpty {
                    Text("No extensions installed yet. Paste a link from the Chrome Web Store above or load a local folder.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 12) {
                        ForEach(extensionManager.installed) { ext in
                            HStack(spacing: 12) {
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.system(size: 16))
                                    .foregroundStyle(ext.enabled ? Color.accentColor : Color.secondary)
                                    .frame(width: 28, height: 28)
                                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(ext.name)
                                            .font(.system(size: 13, weight: .semibold))
                                        Text("v\(ext.version)")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.secondary)
                                        if !ext.fromStore {
                                            Text("Unpacked")
                                                .font(.system(size: 9, weight: .semibold))
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.orange.opacity(0.15), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                    }

                                    if !ext.permissions.isEmpty {
                                        Text(ext.permissions.prefix(4).joined(separator: " • "))
                                            .font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }

                                Spacer()

                                if ext.optionsPath != nil {
                                    Button(action: {
                                        extensionManager.openOptionsPage(for: ext.id)
                                    }) {
                                        Image(systemName: "gearshape")
                                            .font(.system(size: 12))
                                    }
                                    .buttonStyle(.plain)
                                    .help("Extension Options")
                                }

                                Button(action: {
                                    extensionManager.togglePinned(id: ext.id)
                                }) {
                                    Image(systemName: ext.pinned ? "pin.fill" : "pin")
                                        .font(.system(size: 12))
                                        .foregroundStyle(ext.pinned ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                                .help(ext.pinned ? "Unpin from Toolbar" : "Pin to Toolbar")

                                Toggle("", isOn: Binding(
                                    get: { ext.enabled },
                                    set: { _ in extensionManager.toggleEnabled(id: ext.id) }
                                ))
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .controlSize(.small)

                                Button(action: {
                                    extensionManager.remove(id: ext.id)
                                }) {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.red.opacity(0.8))
                                }
                                .buttonStyle(.plain)
                                .help("Remove Extension")
                            }
                            .padding(.vertical, 6)

                            if ext.id != extensionManager.installed.last?.id {
                                Divider().opacity(0.1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func installFromWebStore() {
        let input = webStoreInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        isInstallingExtension = true
        extensionErrorMessage = nil
        Task {
            do {
                try await extensionManager.installFromWebStore(idOrURL: input)
                webStoreInput = ""
                isInstallingExtension = false
            } catch {
                extensionErrorMessage = error.localizedDescription
                isInstallingExtension = false
            }
        }
    }

    private func loadUnpackedFolder() {
        let panel = NSOpenPanel()
        panel.title = "Select Unpacked Extension Folder"
        panel.message = "Choose a directory containing manifest.json"
        panel.prompt = "Load"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let folderURL = panel.url {
            isInstallingExtension = true
            extensionErrorMessage = nil
            Task {
                do {
                    try await extensionManager.installUnpacked(folderURL: folderURL)
                    isInstallingExtension = false
                } catch {
                    extensionErrorMessage = error.localizedDescription
                    isInstallingExtension = false
                }
            }
        }
    }

    // MARK: - UI Helpers
    private func header(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 20, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.primary.opacity(0.03))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func importBookmarksFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Bookmarks"
        panel.message = "Select an exported bookmarks HTML file or bookmarks JSON file from Chrome, Firefox, or Safari."
        panel.prompt = "Import"
        panel.allowedContentTypes = [
            UTType.html,
            UTType.json,
            UTType.plainText,
            UTType.data
        ]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            let count = settings.importBookmarks(from: url)
            withAnimation {
                if count > 0 {
                    importStatusMessage = "Successfully imported \(count) bookmark\(count == 1 ? "" : "s")."
                } else {
                    importStatusMessage = "No new bookmarks found in selected file."
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
                withAnimation {
                    importStatusMessage = nil
                }
            }
        }
    }
}
