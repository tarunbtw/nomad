//
//  BrowserView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Main browser page view combining the top bar, loading progress, and the WebStage.
struct BrowserView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 0) {
            // Top browser chrome
            TopBarView(store: store)

            // Progress bar directly below the top chrome
            if let activeTab = store.activeTab {
                ProgressBarView(tab: activeTab)
            }

            // Web Stage
            ZStack {
                WebStage(tab: store.activeTab)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Calm empty start state when no page is loaded
                if let activeTab = store.activeTab, activeTab.isBlank {
                    EmptyStateView(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background {
            // Native keyboard shortcuts
            Group {
                Button("") { store.newTab() }
                    .keyboardShortcut("t", modifiers: .command)
                Button("") {
                    if let activeId = store.activeTabId { store.closeTab(id: activeId) }
                }
                .keyboardShortcut("w", modifiers: .command)
                Button("") { store.isAddressBarFocused = true }
                    .keyboardShortcut("l", modifiers: .command)
                Button("") { store.reload() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("") { store.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("") { store.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Button("") { store.selectPreviousTab() }
                    .keyboardShortcut("{", modifiers: .command)
                Button("") { store.selectNextTab() }
                    .keyboardShortcut("}", modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
        }
    }
}

/// Minimal start canvas for blank tabs.
private struct EmptyStateView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "safari")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)

            VStack(spacing: 6) {
                Text("Nomad")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.primary)

                Text("Enter a website address or search query to browse")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ShortcutHint(key: "⌘T", label: "New Tab")
                ShortcutHint(key: "⌘L", label: "Focus Address")
                ShortcutHint(key: "⌘W", label: "Close Tab")
            }
            .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onTapGesture {
            store.isAddressBarFocused = true
        }
    }
}

private struct ShortcutHint: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}
