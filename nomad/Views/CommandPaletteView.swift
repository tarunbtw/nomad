//
//  CommandPaletteView.swift
//  nomad
//
//  Created by tarun on 13/10/26.
//

import SwiftUI
import AppKit

/// Item in the Command Palette (⌘K)
struct CommandItem: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let category: Category
    let action: @MainActor () -> Void

    enum Category: String, CaseIterable {
        case tabs = "Open Tabs"
        case actions = "Actions & Tools"
        case history = "History & Bookmarks"
    }

    static func == (lhs: CommandItem, rhs: CommandItem) -> Bool {
        lhs.id == rhs.id
    }
}

/// Floating Spotlight-style Command Palette for Nomad (⌘K).
struct CommandPaletteView: View {
    @ObservedObject var store: BrowserStore
    @ObservedObject var settings: SettingsStore
    let onDismiss: () -> Void

    @State private var query: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isFieldFocused: Bool

    private var allItems: [CommandItem] {
        var items: [CommandItem] = []

        // 1. Open Tabs
        for tab in store.tabs {
            let title = tab.title.isEmpty ? (tab.url?.host ?? "New Tab") : tab.title
            let subtitle = tab.url?.absoluteString ?? "Blank Page"
            items.append(CommandItem(
                id: "tab-\(tab.id.uuidString)",
                title: title,
                subtitle: subtitle,
                icon: tab.isIncognito ? "eye.slash" : "safari",
                shortcut: nil,
                category: .tabs,
                action: {
                    store.selectTab(id: tab.id)
                    onDismiss()
                }
            ))
        }

        // 2. Built-in Actions & Tools
        items.append(CommandItem(
            id: "act-devdrawer",
            title: "Developer Tools (Dev Drawer)",
            subtitle: "DOM Inspector, JS Console, Network & Agent Perception",
            icon: "curlybraces",
            shortcut: "⌘⌥I",
            category: .actions,
            action: {
                if let tab = store.activeTab {
                    tab.isDevDrawerVisible.toggle()
                }
                onDismiss()
            }
        ))

        items.append(CommandItem(
            id: "act-zapper",
            title: "Element Zapper (Hide Clutter)",
            subtitle: "Click any element to hide it permanently on this domain",
            icon: "eye.slash.circle",
            shortcut: "⇧⌘H",
            category: .actions,
            action: {
                store.activeTab?.toggleElementZapper()
                onDismiss()
            }
        ))

        if let tab = store.activeTab, let host = tab.url?.host, ZapperStore.shared.count(for: host) > 0 {
            items.append(CommandItem(
                id: "act-unhide",
                title: "Unhide All Elements on \(host)",
                subtitle: "Restore \(ZapperStore.shared.count(for: host)) hidden elements on this site",
                icon: "arrow.counterclockwise.circle",
                shortcut: nil,
                category: .actions,
                action: {
                    tab.unhideAllZappedElements()
                    onDismiss()
                }
            ))
        }

        items.append(CommandItem(
            id: "act-reader",
            title: "Reading Mode",
            subtitle: "Distraction-free article reader with custom typography",
            icon: "doc.plaintext",
            shortcut: "⇧⌘R",
            category: .actions,
            action: {
                store.activeTab?.toggleReaderMode()
                onDismiss()
            }
        ))

        items.append(CommandItem(
            id: "act-pip",
            title: "Picture-in-Picture (Floating Video)",
            subtitle: "Detach playing video into an always-on-top window",
            icon: "pip.enter",
            shortcut: "⇧⌘P",
            category: .actions,
            action: {
                store.activeTab?.togglePictureInPicture()
                onDismiss()
            }
        ))

        items.append(CommandItem(
            id: "act-newtab",
            title: "New Tab",
            subtitle: "Open a fresh tab",
            icon: "plus",
            shortcut: "⌘T",
            category: .actions,
            action: {
                store.newTab()
                onDismiss()
            }
        ))

        items.append(CommandItem(
            id: "act-newprivate",
            title: "New Private Tab",
            subtitle: "Ephemeral session with zero cookie tracking",
            icon: "eye.slash.fill",
            shortcut: "⇧⌘N",
            category: .actions,
            action: {
                store.newIncognitoTab()
                onDismiss()
            }
        ))

        items.append(CommandItem(
            id: "act-settings",
            title: "Settings & Extensions",
            subtitle: "Manage extensions, downloads, and preferences",
            icon: "gearshape",
            shortcut: "⌘,",
            category: .actions,
            action: {
                store.openSettings()
                onDismiss()
            }
        ))

        // 3. Bookmarks
        for bm in settings.bookmarks {
            items.append(CommandItem(
                id: "bm-\(bm.id.uuidString)",
                title: bm.title,
                subtitle: bm.url,
                icon: "bookmark.fill",
                shortcut: nil,
                category: .history,
                action: {
                    if let url = URL(string: bm.url) {
                        store.activeTab?.load(url: url)
                    }
                    onDismiss()
                }
            ))
        }

        return items
    }

    private var filteredItems: [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if q.isEmpty {
            return allItems
        }
        return allItems.filter {
            $0.title.lowercased().contains(q) ||
            ($0.subtitle?.lowercased().contains(q) ?? false) ||
            $0.category.rawValue.lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            // Dismiss background overlay
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    onDismiss()
                }

            // Command Palette Window
            VStack(spacing: 0) {
                // Search Input Header
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Color.secondary)

                    TextField("Type a command, tab, or bookmark... (Esc to close)", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFieldFocused)
                        .onSubmit {
                            submitCurrentSelection()
                        }

                    if !query.isEmpty {
                        Button(action: { query = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }

                    Text("⌘K")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.85))

                Divider().opacity(0.12)

                // Results List
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 2) {
                            ForEach(Array(filteredItems.enumerated()), id: \.element.id) { index, item in
                                let isSelected = index == selectedIndex
                                Button(action: { item.action() }) {
                                    HStack(spacing: 10) {
                                        Image(systemName: item.icon)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                                            .frame(width: 20)

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                                                .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                                                .lineLimit(1)

                                            if let sub = item.subtitle {
                                                Text(sub)
                                                    .font(.system(size: 10.5))
                                                    .foregroundStyle(.secondary)
                                                    .lineLimit(1)
                                            }
                                        }

                                        Spacer()

                                        if let sc = item.shortcut {
                                            Text(sc)
                                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                                .foregroundStyle(.secondary)
                                                .padding(.horizontal, 4)
                                                .padding(.vertical, 1)
                                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 4))
                                        } else {
                                            Text(item.category.rawValue)
                                                .font(.system(size: 9.5))
                                                .foregroundStyle(.tertiary)
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 6)
                                    .background(
                                        isSelected ? Color.primary.opacity(0.08) : Color.clear,
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .id(item.id)
                            }
                        }
                        .padding(6)
                    }
                    .frame(maxHeight: 320)
                }
            }
            .frame(width: 520)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 24, y: 12)
        }
        .onAppear {
            isFieldFocused = true
            selectedIndex = 0
        }
        .onChange(of: query) { _, _ in
            selectedIndex = 0
        }
    }

    private func submitCurrentSelection() {
        let items = filteredItems
        guard !items.isEmpty, selectedIndex < items.count else { return }
        items[selectedIndex].action()
    }
}
