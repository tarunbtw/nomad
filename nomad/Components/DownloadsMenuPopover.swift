//
//  DownloadsMenuPopover.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import AppKit

/// Clean, minimal downloads dropdown popover in the top toolbar.
struct DownloadsMenuPopover: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject private var manager = DownloadManager.shared
    @ObservedObject private var settings = SettingsStore.shared
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Downloads")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer()

                if !manager.downloads.isEmpty {
                    Button(action: { manager.clearCompleted() }) {
                        Text("Clear")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            Divider().opacity(0.15)

            // Downloads List
            if manager.downloads.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(.top, 16)

                    Text("No Downloads")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 16)
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 4) {
                        ForEach(manager.downloads) { item in
                            DownloadRow(item: item)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 280)
            }

            Divider().opacity(0.15)

            // Footer: Manage Downloads in Settings
            Button(action: {
                isPresented = false
                store.openSettings(section: "Downloads")
            }) {
                HStack(spacing: 8) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("Manage Downloads")
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
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: item.iconName)
                .font(.system(size: 18))
                .foregroundStyle(item.statusColor)
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.suggestedFilename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                switch item.state {
                case .downloading:
                    ProgressView(value: item.progress)
                        .progressViewStyle(.linear)
                        .frame(height: 3)
                case .completed:
                    Text("Downloaded")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(item.errorMessage ?? "Failed")
                        .font(.system(size: 10))
                        .foregroundStyle(.red)
                case .cancelled:
                    Text("Cancelled")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if item.state == .downloading {
                Button(action: { item.cancel() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else if item.state == .completed {
                HStack(spacing: 6) {
                    Button(action: { DownloadManager.shared.openFile(item) }) {
                        Image(systemName: "arrow.up.forward.app")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Open File")

                    Button(action: { DownloadManager.shared.showInFinder(item) }) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Show in Finder")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        .cornerRadius(6)
        .onHover { isHovered = $0 }
    }
}
