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
struct SettingsView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore

    @State private var selectedSection: Section = .appearance
    @State private var newBookmarkTitle: String = ""
    @State private var newBookmarkURL: String = ""
    @State private var hexInputText: String = ""

    enum Section: String, CaseIterable, Identifiable {
        case appearance = "Appearance"
        case bookmarks = "Bookmarks"
        case general = "General"
        case extensions = "Extensions"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .appearance: return "paintbrush"
            case .bookmarks: return "bookmark"
            case .general: return "gearshape"
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
                    case .appearance:
                        appearanceSection
                    case .bookmarks:
                        bookmarksSection
                    case .general:
                        generalSection
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
        .onAppear {
            hexInputText = settings.customBgHex.replacingOccurrences(of: "#", with: "")
        }
    }

    // MARK: - Sidebar Rail
    private var sidebarRail: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Settings")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
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

            Spacer()

            Text("nomad://settings")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.quaternary)
                .padding(16)
        }
    }

    // MARK: - Appearance Section
    private var appearanceSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "Appearance", subtitle: "Customize window canvas, palettes, themes, and background wallpaper.")

            // Theme Setting
            card(title: "Theme") {
                HStack(spacing: 10) {
                    themeOption(id: "system", label: "System", icon: "circle.lefthalf.filled")
                    themeOption(id: "dark", label: "Dark", icon: "moon.fill")
                    themeOption(id: "light", label: "Light", icon: "sun.max.fill")
                }
            }

            // Background Atmosphere (Solid Theme, Custom Hex, or Wallpaper Image)
            card(title: "Start Canvas Atmosphere") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        bgStyleOption(id: "default", label: "Theme Solid", previewColor: Color(nsColor: .windowBackgroundColor))
                        bgStyleOption(id: "hex", label: "Hex Color", previewColor: settings.customBgColor)
                        imageStyleOption
                    }

                    if settings.backgroundStyle == "hex" {
                        Divider().opacity(0.12).padding(.vertical, 2)
                        hexConfigurationView
                    } else if settings.backgroundStyle == "customImage" {
                        Divider().opacity(0.12).padding(.vertical, 2)
                        imageConfigurationView
                    }
                }
            }

            // Window Vibrancy / Glass
            card(title: "Translucent Vibrancy") {
                Toggle(isOn: $settings.isVibrant) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enable Window Blur & Transparency")
                            .font(.system(size: 13, weight: .medium))
                        Text("Applies native behind-window acrylic glass blur to window chrome")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            }
        }
    }

    // MARK: - Bookmarks Section
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "Bookmarks", subtitle: "Manage your saved links and quick navigation targets.")

            // Add Bookmark Form
            card(title: "Add New Bookmark") {
                HStack(spacing: 8) {
                    TextField("Title (e.g. GitHub)", text: $newBookmarkTitle)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                        .frame(maxWidth: 180)

                    TextField("https://...", text: $newBookmarkURL)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))

                    Button("Add") {
                        if !newBookmarkURL.isEmpty {
                            settings.addBookmark(title: newBookmarkTitle, url: newBookmarkURL)
                            newBookmarkTitle = ""
                            newBookmarkURL = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }

            // Bookmarks List
            card(title: "Saved Bookmarks (\(settings.bookmarks.count))") {
                if settings.bookmarks.isEmpty {
                    Text("No bookmarks saved yet.")
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
        }
    }

    // MARK: - Extensions Section
    private var extensionsSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            header(title: "Extensions", subtitle: "WebExtensions runtime and developer unpacked extensions.")

            card(title: "Extension Runtime") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Circle().fill(Color.green).frame(width: 8, height: 8)
                        Text("WebKit Extensions Engine: Configured")
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text("Nomad's WebKit architecture uses shared process pools and user content controllers. Support for loading unpacked extensions from disk is wired for the upcoming milestone.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
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

    private func themeOption(id: String, label: String, icon: String) -> some View {
        let isSelected = settings.theme == id
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.12)) {
                settings.theme = id
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                Text(label)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isSelected ? Color.primary.opacity(0.12) : Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? settings.accentColor.opacity(0.7) : Color.primary.opacity(0.1), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func bgStyleOption(id: String, label: String, previewColor: Color) -> some View {
        let isSelected = settings.backgroundStyle == id
        return Button(action: {
            withAnimation(.easeInOut(duration: 0.12)) {
                settings.backgroundStyle = id
            }
        }) {
            VStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(previewColor)
                    .frame(width: 70, height: 44)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? settings.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )

                Text(label)
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var imageStyleOption: some View {
        let isSelected = settings.backgroundStyle == "customImage"
        let hasImage = !settings.customBgPath.isEmpty && FileManager.default.fileExists(atPath: settings.customBgPath)
        let nsImage = hasImage ? NSImage(contentsOfFile: settings.customBgPath) : nil

        return Button(action: {
            if hasImage {
                withAnimation(.easeInOut(duration: 0.12)) {
                    settings.backgroundStyle = "customImage"
                }
            } else {
                chooseCustomImage()
            }
        }) {
            VStack(spacing: 6) {
                ZStack {
                    if let nsImage = nsImage {
                        Image(nsImage: nsImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 70, height: 44)
                            .clipped()
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(Color.primary.opacity(0.04))
                            .frame(width: 70, height: 44)
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 70, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isSelected ? settings.accentColor : Color.primary.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                )

                Text("Image")
                    .font(.system(size: 11, weight: isSelected ? .medium : .regular))
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var hexConfigurationView: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Text("Color Hex:")
                    .font(.system(size: 12, weight: .medium))

                HStack(spacing: 2) {
                    Text("#")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    TextField("1E1E2E", text: $hexInputText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(width: 70)
                        .onChange(of: hexInputText) { _, val in
                            applyHex(val)
                        }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
                )

                Circle()
                    .fill(settings.customBgColor)
                    .frame(width: 20, height: 20)
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))

                Spacer()

                // Preset Swatches
                HStack(spacing: 6) {
                    ForEach(["1E1E2E", "0F172A", "18181B", "282C34", "000000"], id: \.self) { hex in
                        Button(action: {
                            hexInputText = hex
                            applyHex(hex)
                        }) {
                            Circle()
                                .fill(Color(hex: hex))
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .help("#" + hex)
                    }
                }
            }
        }
    }

    private var imageConfigurationView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(settings.customBgPath.isEmpty ? "No custom wallpaper chosen" : URL(fileURLWithPath: settings.customBgPath).lastPathComponent)
                    .font(.system(size: 12, weight: .medium))
                if !settings.customBgPath.isEmpty {
                    Text(settings.customBgPath)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if !settings.customBgPath.isEmpty {
                Button("Remove") {
                    settings.customBgPath = ""
                    settings.backgroundStyle = "default"
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            }

            Button(settings.customBgPath.isEmpty ? "Choose Image…" : "Change Image…") {
                chooseCustomImage()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private func applyHex(_ text: String) {
        var clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") {
            clean.removeFirst()
        }
        guard clean.count == 6 else { return }
        settings.customBgHex = "#" + clean.uppercased()
    }

    private func chooseCustomImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Set Wallpaper"
        if panel.runModal() == .OK, let url = panel.url {
            settings.customBgPath = url.path
            settings.backgroundStyle = "customImage"
        }
    }
}
