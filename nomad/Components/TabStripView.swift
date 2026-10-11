//
//  TabStripView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Horizontal tab strip housing all open tabs and the new tab button.
/// Hugs its content so the rest of the top bar remains interactive for window dragging and zooming.
struct TabStripView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(store.tabs) { tab in
                    TabItemView(store: store, tab: tab, isActive: tab.id == store.activeTabId)
                }

                // New Tab Button (+)
                Button(action: {
                    store.newTab(url: nil, select: true)
                }) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("New Tab (⌘T)")
            }
            .padding(.trailing, 6)
        }
        .fixedSize(horizontal: true, vertical: false)
    }
}
