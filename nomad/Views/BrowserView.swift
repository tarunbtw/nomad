//
//  BrowserView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Main browser window view coordinating the top bar, loading progress, and tab stage.
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

            // Tab Stage (observes activeTab directly so isBlank changes trigger immediate redraws)
            if let activeTab = store.activeTab {
                TabStageView(store: store, tab: activeTab)
                    .id(activeTab.id)
            } else {
                Color(nsColor: .windowBackgroundColor)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
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

/// Stage hosting the active tab's web view and empty state overlay.
private struct TabStageView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab

    var body: some View {
        ZStack {
            WebStage(tab: tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Calm empty start state when tab has no URL loaded
            if tab.isBlank {
                EmptyStateView(tab: tab, store: store)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeInOut(duration: 0.15), value: tab.isBlank)
    }
}

/// Minimal start canvas for blank tabs: clean centered URL input field.
private struct EmptyStateView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var store: BrowserStore

    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture {
                    isFocused = true
                }

            // Centered "Enter a web address" field
            HStack(spacing: 8) {
                TextField("Enter a web address", text: $text)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .regular))
                    .foregroundStyle(.primary)
                    .focused($isFocused)
                    .onSubmit {
                        submit()
                    }

                if !text.isEmpty {
                    Button(action: { text = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(width: 480, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isFocused ? Color.accentColor.opacity(0.4) : Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isFocused = true
            }
        }
        .onChange(of: store.isAddressBarFocused) { _, focused in
            if focused {
                isFocused = true
                store.isAddressBarFocused = false
            }
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.load(text: trimmed)
        }
    }
}
