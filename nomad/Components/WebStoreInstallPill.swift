//
//  WebStoreInstallPill.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI

/// Contextual 1-click install button that appears in the top toolbar whenever
/// the user is visiting a Chrome Web Store extension detail page.
struct WebStoreInstallPill: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore
    @ObservedObject private var manager = ExtensionManager.shared
    @ObservedObject private var settings = SettingsStore.shared

    @State private var isHovered: Bool = false
    @State private var localIsInstalling: Bool = false
    @State private var installError: String? = nil

    var body: some View {
        if let extensionId = tab.chromeWebStoreExtensionId {
            let isInstalled = manager.installed.contains(where: { $0.id == extensionId })
            let name = tab.chromeWebStoreExtensionName ?? "Extension"

            Button(action: {
                guard !isInstalled && !localIsInstalling else { return }
                install(id: extensionId)
            }) {
                HStack(spacing: 5) {
                    if localIsInstalling || manager.busy != nil {
                        ProgressView()
                            .controlSize(.mini)
                        Text("Installing...")
                            .font(.system(size: 11, weight: .semibold))
                    } else if isInstalled {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                        Text("Added to Nomad")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    } else {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                        Text("Add to Nomad")
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(
                            isInstalled
                                ? Color.primary.opacity(0.06)
                                : Color.primary.opacity(isHovered ? 0.88 : 1.0)
                        )
                )
                .foregroundStyle(isInstalled ? Color.primary : Color(nsColor: .windowBackgroundColor))
            }
            .buttonStyle(.plain)
            .disabled(isInstalled || localIsInstalling)
            .onHover { isHovered = $0 }
            .help(isInstalled ? "\(name) is already installed" : "Install \(name) directly from the Chrome Web Store")
            .alert("Installation Failed", isPresented: Binding(
                get: { installError != nil },
                set: { if !$0 { installError = nil } }
            )) {
                Button("OK") { installError = nil }
            } message: {
                Text(installError ?? "Unknown error")
            }
        }
    }

    private func install(id: String) {
        localIsInstalling = true
        installError = nil
        Task {
            do {
                try await manager.installFromWebStore(idOrURL: id)
                // Automatically pin the newly installed extension to the toolbar
                if let idx = manager.installed.firstIndex(where: { $0.id == id }) {
                    if !manager.installed[idx].pinned {
                        manager.togglePinned(id: id)
                    }
                }
            } catch {
                await MainActor.run {
                    installError = error.localizedDescription
                }
            }
            await MainActor.run {
                localIsInstalling = false
            }
        }
    }
}
