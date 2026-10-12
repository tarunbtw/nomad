//
//  TabStripView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// Horizontal tab strip housing all open tabs and the new tab button.
/// Supports dynamic resizing down to favicon-only mode and silky-smooth visual offset tab rearranging.
struct TabStripView: View {
    @ObservedObject var store: BrowserStore

    private let minTabWidth: CGFloat = 36
    private let maxTabWidth: CGFloat = 180
    private let plusButtonWidth: CGFloat = 26
    private let tabSpacing: CGFloat = 4

    @State private var draggingTabId: UUID? = nil
    @State private var dragOffset: CGFloat = 0
    @State private var isSettling: Bool = false

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
                .frame(height: geo.size.height, alignment: .center)
            } else {
                HStack(spacing: tabSpacing) {
                    tabsHStack(computedTabWidth: computedTabWidth)

                    // Trailing empty space allows native window dragging
                    WindowDragArea()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
        }
    }

    @ViewBuilder
    private func tabsHStack(computedTabWidth: CGFloat) -> some View {
        let count = store.tabs.count
        let step = computedTabWidth + tabSpacing

        HStack(spacing: tabSpacing) {
            ForEach(Array(store.tabs.enumerated()), id: \.element.id) { index, tab in
                let isDragging = draggingTabId == tab.id
                let offset = tabOffset(for: tab, index: index, step: step)

                TabItemView(
                    store: store,
                    tab: tab,
                    isActive: tab.id == store.activeTabId,
                    isDragging: isDragging,
                    tabWidth: computedTabWidth,
                    index: index,
                    count: count,
                    step: step,
                    offsetX: offset,
                    onDragChanged: { translation in
                        handleDragChanged(tabId: tab.id, translation: translation)
                    },
                    onDragEnded: { translation in
                        handleDragEnded(tabId: tab.id, translation: translation, step: step)
                    }
                )
                .animation(draggingTabId == nil ? nil : (isDragging && !isSettling ? nil : .spring(response: 0.18, dampingFraction: 0.95)), value: offset)
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
        .frame(height: 30)
        .padding(.leading, 2)
        .padding(.trailing, 4)
        .coordinateSpace(name: "TabStripSpace")
        .animation(.spring(response: 0.25, dampingFraction: 0.90), value: computedTabWidth)
    }

    private func tabOffset(for tab: Tab, index: Int, step: CGFloat) -> CGFloat {
        guard let draggingId = draggingTabId,
              let draggingIndex = store.tabs.firstIndex(where: { $0.id == draggingId }) else {
            return 0
        }

        if tab.id == draggingId {
            return dragOffset
        }

        let count = store.tabs.count
        let rawShift = Int((dragOffset / step).rounded())
        let targetIndex = min(max(0, draggingIndex + rawShift), count - 1)

        if draggingIndex < targetIndex {
            // Dragging to the right: tabs between (draggingIndex + 1) and targetIndex shift left
            if index > draggingIndex && index <= targetIndex {
                return -step
            }
        } else if draggingIndex > targetIndex {
            // Dragging to the left: tabs between targetIndex and (draggingIndex - 1) shift right
            if index >= targetIndex && index < draggingIndex {
                return step
            }
        }

        return 0
    }

    private func handleDragChanged(tabId: UUID, translation: CGFloat) {
        guard !isSettling else { return }
        if draggingTabId == nil {
            draggingTabId = tabId
            if store.activeTabId != tabId {
                store.selectTab(id: tabId)
            }
        }
        dragOffset = translation
    }

    private func handleDragEnded(tabId: UUID, translation: CGFloat, step: CGFloat) {
        guard !isSettling,
              let draggingIndex = store.tabs.firstIndex(where: { $0.id == tabId }) else {
            draggingTabId = nil
            dragOffset = 0
            isSettling = false
            return
        }

        let count = store.tabs.count
        let rawShift = Int((translation / step).rounded())
        let targetIndex = min(max(0, draggingIndex + rawShift), count - 1)

        isSettling = true

        if targetIndex != draggingIndex {
            let targetOffset = CGFloat(targetIndex - draggingIndex) * step
            withAnimation(.spring(response: 0.18, dampingFraction: 0.95)) {
                dragOffset = targetOffset
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    store.moveTab(from: draggingIndex, to: targetIndex)
                    draggingTabId = nil
                    dragOffset = 0
                    isSettling = false
                }
            }
        } else {
            withAnimation(.spring(response: 0.18, dampingFraction: 0.95)) {
                dragOffset = 0
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                var transaction = Transaction()
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    draggingTabId = nil
                    isSettling = false
                }
            }
        }
    }
}

