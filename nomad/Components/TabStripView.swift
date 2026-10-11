//
//  TabStripView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// Horizontal tab strip housing all open tabs and the new tab button.
/// Supports dynamic resizing down to favicon-only mode and instant, lag-free tab rearranging.
struct TabStripView: View {
    @ObservedObject var store: BrowserStore

    private let minTabWidth: CGFloat = 36
    private let maxTabWidth: CGFloat = 180
    private let plusButtonWidth: CGFloat = 26
    private let tabSpacing: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let count = max(1, store.tabs.count)
            let totalSpacing = CGFloat(count) * tabSpacing
            let availableForTabs = max(minTabWidth, availableWidth - plusButtonWidth - totalSpacing - 8)
            let naturalWidth = availableForTabs / CGFloat(count)
            let computedTabWidth = max(minTabWidth, min(maxTabWidth, naturalWidth))
            let needsScroll = naturalWidth < minTabWidth

            if needsScroll {
                ScrollView(.horizontal, showsIndicators: false) {
                    tabsHStack(computedTabWidth: computedTabWidth)
                }
            } else {
                HStack(spacing: tabSpacing) {
                    tabsHStack(computedTabWidth: computedTabWidth)

                    // Trailing empty space allows native window dragging
                    WindowDragArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }

    @ViewBuilder
    private func tabsHStack(computedTabWidth: CGFloat) -> some View {
        let count = store.tabs.count
        let step = computedTabWidth + tabSpacing

        HStack(spacing: tabSpacing) {
            ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItemView(
                    store: store,
                    tab: tab,
                    isActive: tab.id == store.activeTabId,
                    tabWidth: computedTabWidth,
                    index: index,
                    count: count,
                    step: step
                )
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
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .coordinateSpace(name: "TabStripSpace")
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: store.tabs.map(\.id))
        .animation(.spring(response: 0.28, dampingFraction: 0.82), value: computedTabWidth)
    }
}
