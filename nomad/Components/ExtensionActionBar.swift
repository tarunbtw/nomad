//
//  ExtensionActionBar.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import WebKit

/// Toolbar bar displaying pinned WebExtension action buttons with dynamic badges and popovers.
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

/// An individual extension icon button with action badge, click popover, and context menu.
struct ExtensionActionButton: View {
    let extensionItem: InstalledExtension
    @ObservedObject var manager: ExtensionManager
    @ObservedObject var store: BrowserStore

    @State private var isShowingPopup: Bool = false
    @State private var isHovered: Bool = false

    var body: some View {
        let context = manager.contexts[extensionItem.id]
        let action = context?.action(for: nil)
        let badgeText = action?.badgeText ?? ""
        let badgeColor = Color.accentColor

        Button(action: {
            if let popupPath = extensionItem.popupPath, !popupPath.isEmpty {
                isShowingPopup.toggle()
            } else if let context {
                context.performAction(for: nil)
            }
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
        .onHover { isHovered = $0 }
        .help(action?.label ?? extensionItem.name)
        .popover(isPresented: $isShowingPopup, arrowEdge: .bottom) {
            if let popupPath = extensionItem.popupPath {
                ExtensionPopupHostView(
                    extensionId: extensionItem.id,
                    popupPath: popupPath,
                    isPresented: $isShowingPopup
                )
            }
        }
        .contextMenu {
            if extensionItem.optionsPath != nil {
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

/// Popover container hosting an extension's action popup HTML in a standalone WKWebView.
struct ExtensionPopupHostView: View {
    let extensionId: String
    let popupPath: String
    @Binding var isPresented: Bool

    var body: some View {
        ExtensionPopupRepresentable(extensionId: extensionId, popupPath: popupPath)
            .frame(width: 360, height: 460)
            .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// AppKit bridge for hosting an extension's popup WKWebView.
struct ExtensionPopupRepresentable: NSViewRepresentable {
    let extensionId: String
    let popupPath: String

    func makeNSView(context: Context) -> WKWebView {
        let config = WebKitPool.makeConfiguration()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 360, height: 460), configuration: config)
        webView.customUserAgent = WebKitPool.customUserAgent

        if let popupURL = URL(string: "\(ExtensionManager.scheme)://\(extensionId)/\(popupPath)") {
            webView.load(URLRequest(url: popupURL))
        }
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}
