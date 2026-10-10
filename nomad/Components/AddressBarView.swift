//
//  AddressBarView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Minimal omnibox/address bar supporting URL navigation and search.
struct AddressBarView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab

    @State private var text: String = ""
    @FocusState private var isFocused: Bool
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            // Leading icon (Lock for HTTPS, Globe for HTTP, Magnifying glass for blank)
            Image(systemName: leadingIconName)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.secondary)
                .padding(.leading, 8)

            // Address text field
            TextField("Search or enter website address", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12, weight: .regular))
                .focused($isFocused)
                .onSubmit {
                    submitAddress()
                }
                .onExitCommand {
                    cancelEditing()
                }

            // Clear button if editing and non-empty
            if isFocused && !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
            }
        }
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isFocused ? Color(nsColor: .controlBackgroundColor) : (isHovered ? Color.primary.opacity(0.07) : Color.primary.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isFocused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
        )
        .onHover { isHovered = $0 }
        .onAppear {
            syncTextWithTab()
        }
        .onChange(of: tab.url) { _, _ in
            if !isFocused {
                syncTextWithTab()
            }
        }
        .onChange(of: store.isAddressBarFocused) { _, shouldFocus in
            if shouldFocus {
                isFocused = true
                store.isAddressBarFocused = false
            }
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                // When focused, populate full URL string for editing
                text = tab.url?.absoluteString ?? ""
            } else {
                syncTextWithTab()
            }
        }
    }

    private var leadingIconName: String {
        guard let url = tab.url, !tab.isBlank else { return "magnifyingglass" }
        if url.scheme == "https" {
            return "lock.fill"
        } else if url.scheme == "http" {
            return "globe"
        } else {
            return "doc.text"
        }
    }

    private func syncTextWithTab() {
        if let url = tab.url, !tab.isBlank {
            // Display host or path nicely when not focused
            if let host = url.host {
                let displayPath = url.path.isEmpty || url.path == "/" ? "" : url.path
                text = host + displayPath
            } else {
                text = url.absoluteString
            }
        } else {
            text = ""
        }
    }

    private func submitAddress() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.load(text: trimmed)
        }
        isFocused = false
    }

    private func cancelEditing() {
        syncTextWithTab()
        isFocused = false
    }
}
