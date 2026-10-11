//
//  TuneView.swift
//  nomad
//
//  Created by tarun on 11/10/26.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Dedicated Canvas Tuning page (nomad://tune).
/// Focused exclusively on customizing the start canvas atmosphere, window vibrancy, and system theme.
struct TuneView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore

    @State private var hexInputText: String = ""

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 26) {
                // Header
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(settings.accentColor)
                        Text("Tune")
                            .font(.system(size: 20, weight: .bold))
                    }
                    Text("Personalize your start canvas atmosphere, themes, and translucent vibrancy.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .padding(.bottom, 4)

                // Theme Setting Card
                card(title: "Theme Mode") {
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

                // Window Vibrancy / Acrylic Glass
                card(title: "Translucent Vibrancy") {
                    Toggle(isOn: $settings.isVibrant) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Enable Window Blur & Transparency")
                                .font(.system(size: 13, weight: .medium))
                            Text("Applies native behind-window acrylic glass blur across the window canvas")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                // Internal scheme indicator
                HStack {
                    Text("nomad://tune")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.quaternary)
                    Spacer()
                }
                .padding(.top, 8)
            }
            .padding(32)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            settings.isVibrant
                ? Color(nsColor: .windowBackgroundColor).opacity(0.4)
                : Color(nsColor: .windowBackgroundColor)
        )
        .onAppear {
            hexInputText = settings.customBgHex.replacingOccurrences(of: "#", with: "")
        }
    }

    // MARK: - Components
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
                    .font(.system(size: 11, weight: .medium))
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
                    .font(.system(size: 11, weight: .medium))
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
