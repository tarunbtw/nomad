//
//  FindInPageView.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import AppKit

/// Sleek floating Find in Page search bar (⌘F) positioned in the top-right corner of the web canvas.
struct FindInPageView: View {
    @ObservedObject var tab: Tab
    @ObservedObject var settings = SettingsStore.shared
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("Find in page...", text: $tab.findQuery)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .focused($isFieldFocused)
                .frame(width: 150)
                .onSubmit {
                    tab.findInPage(tab.findQuery, forward: true)
                }
                .onChange(of: tab.findQuery) { _, newQuery in
                    tab.findInPage(newQuery, forward: true)
                }

            if !tab.findQuery.isEmpty {
                Text(tab.findHasMatches ? "Match found" : "No matches")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(tab.findHasMatches ? Color.secondary : Color.red)
            }

            // Previous match (Shift+Enter or Up)
            Button(action: { tab.findInPage(tab.findQuery, forward: false) }) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tab.findQuery.isEmpty)
            .help("Previous match (Shift+Enter)")

            // Next match (Enter or Down)
            Button(action: { tab.findInPage(tab.findQuery, forward: true) }) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(tab.findQuery.isEmpty)
            .help("Next match (Enter)")

            Divider()
                .frame(height: 12)
                .opacity(0.3)

            // Close button (Esc)
            Button(action: { tab.closeFind() }) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 8, x: 0, y: 3)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
                )
        }
        .onAppear {
            isFieldFocused = true
        }
        .onExitCommand {
            tab.closeFind()
        }
    }
}
