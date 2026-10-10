//
//  TabItemView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// An individual tab pill in the tab bar.
/// Double-clicking expands the tab pill into an inline URL/search field.
/// Clicking anywhere outside the expanded field dismisses it back to the normal tab pill.
struct TabItemView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab
    let isActive: Bool

    @State private var isHovered: Bool = false
    @State private var isEditing: Bool = false
    @State private var editText: String = ""
    @FocusState private var isFieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            if isEditing {
                // Expanded URL Editing Mode
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 2)

                TextField("Enter a web address", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .regular))
                    .focused($isFieldFocused)
                    .onSubmit {
                        submitEdit()
                    }
                    .onExitCommand {
                        cancelEdit()
                    }

                Button(action: { cancelEdit() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            } else {
                // Normal Tab Pill Mode
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

                // Tab Title / Host
                Text(displayTitle)
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
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .frame(minWidth: isEditing ? 240 : 100, maxWidth: isEditing ? 420 : 200)
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isEditing)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isEditing ? Color.accentColor.opacity(0.5) : (isActive ? Color.primary.opacity(0.06) : Color.clear), lineWidth: 1)
        )
        // Detects clicks outside the tab pill while editing and cancels editing immediately
        .background {
            if isEditing {
                ClickOutsideDetector {
                    cancelEdit()
                }
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2) {
            startEditing()
        }
        .simultaneousGesture(
            TapGesture(count: 1).onEnded {
                if !isEditing {
                    store.selectTab(id: tab.id)
                }
            }
        )
        .onChange(of: isActive) { _, active in
            if !active && isEditing {
                cancelEdit()
            }
        }
        .onChange(of: store.isAddressBarFocused) { _, focused in
            if focused && isActive && !tab.isBlank {
                startEditing()
                store.isAddressBarFocused = false
            }
        }
    }

    private var displayTitle: String {
        if let host = tab.url?.host, !tab.isBlank {
            return host
        }
        return tab.title
    }

    private func startEditing() {
        editText = tab.url?.absoluteString ?? (tab.title == "New Tab" ? "" : tab.title)
        isEditing = true
        DispatchQueue.main.async {
            isFieldFocused = true
        }
    }

    private func submitEdit() {
        let trimmed = editText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            tab.load(text: trimmed)
        }
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}

/// AppKit view that monitors window mouse down events to detect clicks outside its bounds.
private struct ClickOutsideDetector: NSViewRepresentable {
    let onOutsideClick: () -> Void

    func makeNSView(context: Context) -> ClickOutsideHostView {
        let view = ClickOutsideHostView()
        view.onOutsideClick = onOutsideClick
        return view
    }

    func updateNSView(_ nsView: ClickOutsideHostView, context: Context) {
        nsView.onOutsideClick = onOutsideClick
    }
}

private final class ClickOutsideHostView: NSView {
    var onOutsideClick: (() -> Void)?
    private var eventMonitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            startMonitoring()
        } else {
            stopMonitoring()
        }
    }

    private func startMonitoring() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            guard let self = self, let window = self.window, event.window === window else {
                return event
            }
            let locationInView = self.convert(event.locationInWindow, from: nil)
            if !self.bounds.contains(locationInView) {
                DispatchQueue.main.async {
                    self.onOutsideClick?()
                }
            }
            return event
        }
    }

    private func stopMonitoring() {
        if let eventMonitor = eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
            self.eventMonitor = nil
        }
    }

    deinit {
        stopMonitoring()
    }
}
