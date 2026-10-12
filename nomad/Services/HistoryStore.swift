//
//  HistoryStore.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import Foundation
import Combine

/// Represents a visited URL record in Nomad's history.
struct HistoryItem: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    let url: String
    let title: String
    let timestamp: Date

    var host: String {
        URL(string: url)?.host ?? ""
    }
}

/// Lightweight, fast local history storage for visited pages and address bar suggestions.
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var items: [HistoryItem] = []

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let nomadDir = appSupport.appendingPathComponent("nomad", isDirectory: true)
        return nomadDir.appendingPathComponent("history.json")
    }

    private init() {
        load()
    }

    /// Records a site visit, ignoring internal schemes and blank pages.
    func addVisit(url: URL, title: String) {
        let urlString = url.absoluteString
        guard url.scheme == "http" || url.scheme == "https",
              !urlString.isEmpty, urlString != "about:blank" else { return }

        let cleanTitle = title.isEmpty ? (url.host ?? urlString) : title
        let record = HistoryItem(url: urlString, title: cleanTitle, timestamp: Date())

        // Deduplicate recent consecutive visits to same URL
        if let first = items.first, first.url == urlString {
            items[0] = record
        } else {
            items.insert(record, at: 0)
            if items.count > 2000 {
                items.removeLast(items.count - 2000)
            }
        }

        save()
    }

    /// Returns fuzzy autocomplete suggestions matching typed query.
    func suggestions(for query: String, limit: Int = 5) -> [HistoryItem] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        var seenHosts = Set<String>()
        var results: [HistoryItem] = []

        for item in items {
            let host = item.host.lowercased()
            let title = item.title.lowercased()
            let url = item.url.lowercased()

            if (host.contains(trimmed) || title.contains(trimmed) || url.contains(trimmed)) && !seenHosts.contains(host) {
                seenHosts.insert(host)
                results.append(item)
                if results.count >= limit { break }
            }
        }

        return results
    }

    func clear() {
        items.removeAll()
        save()
    }

    private func save() {
        let url = HistoryStore.storageURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        let url = HistoryStore.storageURL
        if let data = try? Data(contentsOf: url),
           let loaded = try? JSONDecoder().decode([HistoryItem].self, from: data) {
            self.items = loaded
        }
    }
}
