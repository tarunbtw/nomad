//
//  OmniboxSuggestionsView.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import SwiftUI
import AppKit

/// Unified suggestion model for bookmarks, history visits, and fallback web search queries.
struct OmniboxSuggestionItem: Identifiable, Equatable {
    var id: String { "\(kind):\(url.absoluteString)" }
    
    enum Kind: Equatable {
        case bookmark
        case history
        case search
    }

    let kind: Kind
    let title: String
    let subtitle: String
    let url: URL
}

/// Sleek floating suggestions popover matching user input across Bookmarks and History.
struct OmniboxSuggestionsView: View {
    let query: String
    let width: CGFloat
    let onSelect: (URL) -> Void

    @ObservedObject private var history = HistoryStore.shared
    @ObservedObject private var settings = SettingsStore.shared
    @State private var hoveredId: String? = nil

    private var items: [OmniboxSuggestionItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()

        var results: [OmniboxSuggestionItem] = []
        var seenURLs = Set<String>()

        // 1. Matching Bookmarks
        for bm in settings.bookmarks {
            if bm.title.localizedCaseInsensitiveContains(lower) || bm.url.localizedCaseInsensitiveContains(lower) {
                if let url = URL(string: bm.url) {
                    seenURLs.insert(bm.url.lowercased())
                    let host = url.host ?? bm.url
                    results.append(OmniboxSuggestionItem(
                        kind: .bookmark,
                        title: bm.title.isEmpty ? host : bm.title,
                        subtitle: host,
                        url: url
                    ))
                    if results.count >= 3 { break }
                }
            }
        }

        // 2. Matching History visits
        let historyHits = history.suggestions(for: lower, limit: 5)
        for h in historyHits {
            let lowerURL = h.url.lowercased()
            if !seenURLs.contains(lowerURL) {
                seenURLs.insert(lowerURL)
                if let url = URL(string: h.url) {
                    results.append(OmniboxSuggestionItem(
                        kind: .history,
                        title: h.title.isEmpty ? h.host : h.title,
                        subtitle: h.host,
                        url: url
                    ))
                    if results.count >= 5 { break }
                }
            }
        }

        // 3. Search Engine Fallback suggestion
        let searchBase = settings.searchEngineBaseURL
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        if let searchURL = URL(string: "\(searchBase)\(encoded)") {
            results.append(OmniboxSuggestionItem(
                kind: .search,
                title: "Search for \"\(trimmed)\"",
                subtitle: settings.searchEngineName,
                url: searchURL
            ))
        }

        return results
    }

    var body: some View {
        let suggestions = items
        if !suggestions.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(suggestions) { item in
                    suggestionRow(item)
                }
            }
            .padding(.vertical, 4)
            .frame(width: width)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.96))
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 5)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
        }
    }

    private func suggestionRow(_ item: OmniboxSuggestionItem) -> some View {
        let isHovered = hoveredId == item.id

        return Button(action: {
            onSelect(item.url)
        }) {
            HStack(spacing: 9) {
                // Leading Icon
                Group {
                    switch item.kind {
                    case .bookmark:
                        Image(systemName: "bookmark.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(settings.accentColor)
                    case .history:
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                    case .search:
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 16, height: 16)

                // Title & Subtitle
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.title)
                        .font(.system(size: 12, weight: item.kind == .search ? .regular : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Trailing Category Pill
                Text(badgeTitle(for: item.kind))
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.04), in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isHovered ? settings.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { isHovered in
            if isHovered {
                hoveredId = item.id
            } else if hoveredId == item.id {
                hoveredId = nil
            }
        }
    }

    private func badgeTitle(for kind: OmniboxSuggestionItem.Kind) -> String {
        switch kind {
        case .bookmark: return "Bookmark"
        case .history: return "History"
        case .search: return "Search"
        }
    }
}
