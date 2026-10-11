//
//  ExtensionsMenuPopover.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import WebKit

/// Browser extensions menu popover (triggered by clicking the puzzle icon in the top toolbar).
/// Displays all installed extensions, quick pin/toggle controls, contextual Web Store installer,
/// and a direct "Manage Extensions" link to nomad://settings.
struct ExtensionsMenuPopover: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool

    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Extensions")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer()
                let activeCount = manager.installed.filter { $0.enabled }.count
                if !manager.installed.isEmpty {
                    Text("\(activeCount) active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            // Contextual Chrome Web Store quick install card
            if let extId = tab.chromeWebStoreExtensionId {
                contextualWebStoreCard(extensionId: extId)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }

            Divider().opacity(0.15)

            // Installed Extensions List
            if manager.installed.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 26))
                        .foregroundStyle(.secondary.opacity(0.7))
                        .padding(.top, 10)

                    Text("No Extensions Installed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)

                    Text("Install your favorite extensions directly from the Chrome Web Store.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)

                    Button(action: {
                        isPresented = false
                        store.newTab(url: URL(string: "https://chromewebstore.google.com")!, select: true)
                    }) {
                        Text("Open Chrome Web Store")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(settings.accentColor)
                            .foregroundStyle(.white)
                            .cornerRadius(6)
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                    .padding(.bottom, 8)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 2) {
                        ForEach(manager.installed) { ext in
                            ExtensionMenuRow(
                                ext: ext,
                                manager: manager,
                                store: store,
                                isPresented: $isPresented
                            )
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 260)
            }

            Divider().opacity(0.15)

            // Footer: Manage Extensions link
            Button(action: {
                isPresented = false
                store.openSettings(section: "Extensions")
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Manage Extensions")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .frame(width: 310)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Contextual Store Card
    private func contextualWebStoreCard(extensionId: String) -> some View {
        let isInstalled = manager.installed.contains(where: { $0.id == extensionId })
        let name = tab.chromeWebStoreExtensionName ?? "Store Extension"

        return HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(settings.accentColor)

            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(isInstalled ? "Already installed" : "Chrome Web Store extension")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isInstalled {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.green)
            } else {
                Button(action: {
                    Task {
                        try? await manager.installFromWebStore(idOrURL: extensionId)
                        if let idx = manager.installed.firstIndex(where: { $0.id == extensionId }) {
                            if !manager.installed[idx].pinned {
                                manager.togglePinned(id: extensionId)
                            }
                        }
                    }
                }) {
                    Text("Add to Nomad")
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(settings.accentColor)
                        .foregroundStyle(.white)
                        .cornerRadius(6)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

/// An individual extension item row inside the Extensions popover menu.
private struct ExtensionMenuRow: View {
    let ext: InstalledExtension
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var store: BrowserStore
    @Binding var isPresented: Bool

    @State private var isHovered: Bool = false
    @ObservedObject private var settings = SettingsStore.shared

    var body: some View {
        let context = manager.contexts[ext.id]
        let action = context?.action(for: nil)

        HStack(spacing: 10) {
            // Extension Icon
            if let nsImage = action?.icon(for: CGSize(width: 16, height: 16)) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 16, height: 16)
            } else {
                Image(systemName: "puzzlepiece.extension")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .frame(width: 16, height: 16)
            }

            // Name and Version
            VStack(alignment: .leading, spacing: 1) {
                Text(ext.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(ext.enabled ? Color.primary : Color.secondary)
                    .lineLimit(1)

                Text("v\(ext.version)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Pin to TopBar Button
            Button(action: {
                manager.togglePinned(id: ext.id)
            }) {
                Image(systemName: ext.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(ext.pinned ? settings.accentColor : Color.secondary.opacity(0.7))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(ext.pinned ? "Unpin from toolbar" : "Pin to toolbar")

            // Enable / Disable Toggle
            Toggle("", isOn: Binding(
                get: { ext.enabled },
                set: { _ in manager.toggleEnabled(id: ext.id) }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if ext.optionsPath != nil {
                Button("Options") {
                    isPresented = false
                    manager.openOptionsPage(for: ext.id)
                }
            }
            Button(ext.pinned ? "Unpin from Toolbar" : "Pin to Toolbar") {
                manager.togglePinned(id: ext.id)
            }
            Divider()
            Button(ext.enabled ? "Disable" : "Enable") {
                manager.toggleEnabled(id: ext.id)
            }
            Button("Remove Extension", role: .destructive) {
                manager.remove(id: ext.id)
            }
        }
    }
}
