//
//  ZapperStore.swift
//  nomad
//
//  Created by tarun on 13/10/26.
//

import Foundation
import Combine

/// Manages persistently zapped (hidden) DOM elements per hostname.
/// Injects custom CSS rules before document start so distracting clutter never flickers.
@MainActor
final class ZapperStore: ObservableObject {
    static let shared = ZapperStore()

    @Published private(set) var zappedByHost: [String: [String]] = [:]

    private let fileURL: URL

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let nomadDir = appSupport.appendingPathComponent("nomad", isDirectory: true)
        try? FileManager.default.createDirectory(at: nomadDir, withIntermediateDirectories: true)
        self.fileURL = nomadDir.appendingPathComponent("zapped_elements.json")
        load()
    }

    /// Loads saved rules from disk
    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            return
        }
        self.zappedByHost = decoded
    }

    /// Saves rules to disk atomically
    private func save() {
        guard let data = try? JSONEncoder().encode(zappedByHost) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Records a newly zapped selector for a specific domain host
    func addSelector(_ selector: String, for host: String) {
        guard !selector.isEmpty, !host.isEmpty else { return }
        var current = zappedByHost[host] ?? []
        if !current.contains(selector) {
            current.append(selector)
            zappedByHost[host] = current
            save()
        }
    }

    /// Removes a zapped selector for a specific domain host
    func removeSelector(_ selector: String, for host: String) {
        guard var current = zappedByHost[host] else { return }
        current.removeAll { $0 == selector }
        if current.isEmpty {
            zappedByHost.removeValue(forKey: host)
        } else {
            zappedByHost[host] = current
        }
        save()
    }

    /// Clears all zapped selectors for a specific host
    func clearSelectors(for host: String) {
        zappedByHost.removeValue(forKey: host)
        save()
    }

    /// Returns the list of zapped selectors for a domain
    func selectors(for host: String) -> [String] {
        return zappedByHost[host] ?? []
    }

    /// Returns generated CSS to permanently suppress zapped elements
    func cssRule(for host: String) -> String {
        let items = selectors(for: host)
        guard !items.isEmpty else { return "" }
        let combinedSelectors = items.joined(separator: ", ")
        return "\(combinedSelectors) { display: none !important; }"
    }

    /// Returns the number of zapped elements for a host
    func count(for host: String) -> Int {
        return zappedByHost[host]?.count ?? 0
    }
}
