//
//  TabItemView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// An individual tab pill in the tab bar.
struct TabItemView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab
    let isActive: Bool

    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Loading indicator or status icon
            if tab.isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .scaleEffect(0.65)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: tab.isBlank ? "sparkles" : "globe")
                    .font(.system(size: 10, weight: .regular))
                    .foregroundStyle(isActive ? .primary : .secondary)
            }

            // Tab Title
            Text(tab.title)
                .font(.system(size: 11, weight: isActive ? .medium : .regular))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Close button (visible when hovered or active)
            if isHovered || isActive {
                Button(action: {
                    store.closeTab(id: tab.id)
                }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Close Tab (⌘W)")
            } else {
                Spacer().frame(width: 16)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .frame(minWidth: 90, maxWidth: 180)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(isActive ? Color.primary.opacity(0.06) : Color.clear, lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onHover { isHovered = $0 }
        .onTapGesture {
            store.selectTab(id: tab.id)
        }
    }
}
