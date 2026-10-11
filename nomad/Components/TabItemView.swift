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
/// Immediate sliding tab drag on any tab (active or inactive) without moving the window.
struct TabItemView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var tab: Tab
    let isActive: Bool
    let tabWidth: CGFloat
    let index: Int
    let count: Int
    let step: CGFloat

    @State private var isHovered: Bool = false
    @State private var isEditing: Bool = false
    @State private var editText: String = ""
    @State private var lastClickTime: TimeInterval = 0
    @FocusState private var isFieldFocused: Bool

    // Search drag physics state
    @State private var held: Bool = false
    @State private var from: Int = 0
    @State private var travel: CGFloat = 0

    var body: some View {
        let shift = held ? travel - CGFloat(index - from) * step : 0

        HStack(spacing: 0) {
            if isEditing {
                // Expanded URL Editing Mode
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 6)

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
                    .padding(.trailing, 6)
                }
            } else {
                // Standard Tab Pill Content
                HStack(spacing: 0) {
                    if tabWidth < 50 {
                        // Compact favicon-only mode (Close button when hovered)
                        ZStack {
                            if isHovered {
                                Button(action: { store.closeTab(id: tab.id) }) {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 18, height: 18)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .help("Close Tab (⌘W)")
                            } else {
                                tabIconView
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        // Standard & Medium width mode
                        HStack(spacing: 6) {
                            tabIconView

                            if tabWidth >= 70 {
                                Text(displayTitle)
                                    .font(.system(size: 11, weight: isActive ? .medium : .regular))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .foregroundStyle(isActive ? .primary : .secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.leading, 8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: tabWidth < 70 ? .center : .leading)

                        // Close button on trailing edge
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
                            .padding(.trailing, 6)
                            .help("Close Tab (⌘W)")
                        } else if tabWidth >= 70 {
                            Spacer().frame(width: 14)
                        }
                    }
                }
            }
        }
        .frame(height: 30)
        .frame(width: isEditing ? max(tabWidth, 280) : tabWidth)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(isActive ? Color.primary.opacity(0.08) : (isHovered ? Color.primary.opacity(0.04) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(isEditing ? Color.accentColor.opacity(0.5) : (isActive ? Color.primary.opacity(0.06) : Color.clear), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 7))
        .onHover { isHovered = $0 }
        .offset(x: shift, y: 0)
        .transaction { if held { $0.animation = nil } }
        .zIndex(held ? 100 : (isActive ? 1 : 0))
        .shadow(color: .black.opacity(held ? 0.16 : 0), radius: 10, y: 3)
        .scaleEffect(held ? 1.02 : 1.0)
        .gesture(
            isEditing ? nil :
            DragGesture(minimumDistance: 2, coordinateSpace: .named("TabStripSpace"))
                .onChanged { value in
                    if !held {
                        held = true
                        from = index
                    }
                    travel = value.translation.width
                    let target = min(max(0, from + Int((travel / step).rounded())), count - 1)
                    if target != index {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                            store.moveTab(from: index, to: target)
                        }
                        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                    }
                }
                .onEnded { _ in
                    store.selectTab(id: tab.id)
                    withAnimation(.spring(response: 0.25, dampingFraction: 0.82)) {
                        held = false
                        travel = 0
                    }
                }
        )
        .onTapGesture {
            guard !isEditing else { return }
            let now = ProcessInfo.processInfo.systemUptime
            if now - lastClickTime < 0.35 {
                startEditing()
            } else {
                store.selectTab(id: tab.id)
            }
            lastClickTime = now
        }
        .background {
            if isEditing {
                ClickOutsideDetector {
                    cancelEdit()
                }
            }
        }
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

    @ViewBuilder
    private var tabIconView: some View {
        if tab.isLoading {
            ProgressView()
                .controlSize(.mini)
                .scaleEffect(0.65)
                .frame(width: 14, height: 14)
        } else if let favicon = tab.favicon {
            Image(nsImage: favicon)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 14, height: 14)
                .clipShape(RoundedRectangle(cornerRadius: 3))
        } else {
            Image(systemName: iconName)
                .font(.system(size: 10, weight: .regular))
                .foregroundStyle(isActive ? .primary : .secondary)
                .frame(width: 14, height: 14)
        }
    }

    private var iconName: String {
        if tab.isInternalPage {
            return (tab.url?.host == "tune") ? "slider.horizontal.3" : "gearshape.fill"
        }
        return tab.isBlank ? "sparkles" : "globe"
    }

    private var displayTitle: String {
        if tab.isInternalPage {
            return tab.title
        }
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
