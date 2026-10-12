//
//  ExtensionActionBar.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import WebKit

/// Toolbar bar displaying pinned WebExtension action buttons with dynamic badges and native popovers.
struct ExtensionActionBar: View {
    @ObservedObject var manager = ExtensionManager.shared
    @ObservedObject var store: BrowserStore

    var body: some View {
        let pinned = manager.installed.filter { $0.enabled && $0.pinned }
        
        if !pinned.isEmpty {
            HStack(spacing: 2) {
                ForEach(pinned) { ext in
                    ExtensionActionButton(extensionItem: ext, manager: manager, store: store)
                }
            }
            .padding(.trailing, 2)
        }
    }
}

/// An individual extension icon button with action badge, native WebKit popover, and context menu.
struct ExtensionActionButton: View {
    let extensionItem: InstalledExtension
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var store: BrowserStore

    @State private var anchorView: NSView? = nil
    @State private var isHovered: Bool = false

    var body: some View {
        let context = manager.contexts[extensionItem.id]
        let action = context?.action(for: nil)
        let badgeText = action?.badgeText ?? ""
        let badgeColor = Color.accentColor

        Button(action: {
            manager.activate(extensionItem.id)
        }) {
            ZStack(alignment: .bottomTrailing) {
                if let context, let nsImage = context.action(for: nil)?.icon(for: CGSize(width: 16, height: 16)) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.primary)
                }

                if !badgeText.isEmpty {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(badgeColor)
                        )
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: 24, height: 24)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(ExtensionAnchor(id: extensionItem.id))
        .onHover { isHovered = $0 }
        .help(action?.label ?? extensionItem.name)
        .contextMenu {
            if extensionItem.optionsPath != nil || context?.optionsPageURL != nil {
                Button("Options") {
                    manager.openOptionsPage(for: extensionItem.id)
                }
            }
            Button(extensionItem.pinned ? "Unpin from Toolbar" : "Pin to Toolbar") {
                manager.togglePinned(id: extensionItem.id)
            }
            Divider()
            Button("Disable") {
                manager.toggleEnabled(id: extensionItem.id)
            }
            Button("Remove Extension", role: .destructive) {
                manager.remove(id: extensionItem.id)
            }
        }
    }
}

/// A real view under the button so the extension popup hangs accurately from it.
struct ExtensionAnchor: NSViewRepresentable {
    let id: String

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        ExtensionManager.shared.anchors[id] = WeakView(view)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}
