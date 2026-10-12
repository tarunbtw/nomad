//
//  SettingsStore.swift
//  nomad
//
//  Created by tarun on 11/10/26.
//

import SwiftUI
import Combine

/// Central store for app preferences, appearance customizations, and bookmarks.
@MainActor
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()

    // MARK: - Appearance Preferences
    @AppStorage("nomad.theme") var theme: String = "system" {
        didSet {
            applyTheme()
            objectWillChange.send()
        }
    }

    @AppStorage("nomad.windowVibrancy") var isVibrant: Bool = false {
        didSet { objectWillChange.send() }
    }

    @AppStorage("nomad.backgroundStyle") var backgroundStyle: String = "default" {
        didSet { objectWillChange.send() }
    }

    @AppStorage("nomad.customBgHex") var customBgHex: String = "#1E1E2E" {
        didSet { objectWillChange.send() }
    }

    @AppStorage("nomad.customBgPath") var customBgPath: String = "" {
        didSet {
            loadCustomBgImage()
            objectWillChange.send()
        }
    }

    /// Pre-loaded and cached background image to eliminate disk read thrashing during rendering
    @Published var cachedCustomBgImage: NSImage? = nil

    func loadCustomBgImage() {
        guard !customBgPath.isEmpty, FileManager.default.fileExists(atPath: customBgPath) else {
            cachedCustomBgImage = nil
            return
        }
        cachedCustomBgImage = NSImage(contentsOfFile: customBgPath)
    }

    @AppStorage("nomad.searchEngine") var searchEngine: String = "duckduckgo" {
        didSet { objectWillChange.send() }
    }

    // MARK: - Navigation State
    @AppStorage("nomad.settings.activeSection") var activeSection: String = "General" {
        didSet { objectWillChange.send() }
    }

    // MARK: - Bookmarks State
    @Published var bookmarks: [Bookmark] = []

    private let bookmarksKey = "nomad.bookmarks.json"

    init() {
        loadBookmarks()
        loadCustomBgImage()
        applyTheme()
    }

    func applyTheme() {
        switch theme {
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        default:
            NSApp.appearance = nil
        }
    }

    // MARK: - Color & Theme Resolvers
    var colorScheme: ColorScheme? {
        switch theme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    var accentColor: Color {
        Color(red: 1.0, green: 0.44, blue: 0.0) // Nomad Amber
    }

    var customBgColor: Color {
        Color(hex: customBgHex)
    }

    var searchEngineBaseURL: String {
        switch searchEngine {
        case "google": return "https://www.google.com/search?q="
        case "kagi": return "https://kagi.com/search?q="
        case "bing": return "https://www.bing.com/search?q="
        default: return "https://duckduckgo.com/?q="
        }
    }

    // MARK: - Bookmark Operations
    private func normalizeURL(_ url: String) -> String {
        var str = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while str.hasSuffix("/") {
            str.removeLast()
        }
        return str
    }

    func isBookmarked(_ urlString: String) -> Bool {
        let target = normalizeURL(urlString)
        guard !target.isEmpty else { return false }
        return bookmarks.contains { normalizeURL($0.url) == target }
    }

    func addBookmark(title: String, url: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty, !isBookmarked(cleanURL) else { return }

        let newBookmark = Bookmark(
            title: cleanTitle.isEmpty ? cleanURL : cleanTitle,
            url: cleanURL
        )
        bookmarks.append(newBookmark)
        saveBookmarks()
    }

    func removeBookmark(id: UUID) {
        bookmarks.removeAll { $0.id == id }
        saveBookmarks()
    }

    func removeBookmark(url urlString: String) {
        let target = normalizeURL(urlString)
        guard !target.isEmpty else { return }
        bookmarks.removeAll { normalizeURL($0.url) == target }
        saveBookmarks()
    }

    /// Imports bookmarks from an HTML export (Chrome/Firefox/Safari) or Chrome JSON file.
    /// Returns the number of newly added bookmarks.
    @discardableResult
    func importBookmarks(from fileURL: URL) -> Int {
        guard let data = try? Data(contentsOf: fileURL) else { return 0 }

        var imported: [(title: String, url: String)] = []

        // 1. Try Chrome JSON format
        if let jsonBookmarks = parseJSONBookmarks(data), !jsonBookmarks.isEmpty {
            imported = jsonBookmarks
        } else if let htmlContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) {
            // 2. Try Netscape HTML Bookmarks format (used by Chrome, Firefox, Safari)
            imported = parseHTMLBookmarks(htmlContent)
        }

        var addedCount = 0
        for item in imported {
            let cleanURL = item.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleanURL.isEmpty, !isBookmarked(cleanURL) else { continue }
            let cleanTitle = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            bookmarks.append(Bookmark(
                title: cleanTitle.isEmpty ? cleanURL : cleanTitle,
                url: cleanURL
            ))
            addedCount += 1
        }

        if addedCount > 0 {
            saveBookmarks()
        }
        return addedCount
    }

    private func parseHTMLBookmarks(_ content: String) -> [(title: String, url: String)] {
        var results: [(title: String, url: String)] = []
        let pattern = #"(?i)<a\s+[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)<\/a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return [] }
        let nsRange = NSRange(content.startIndex..<content.endIndex, in: content)
        let matches = regex.matches(in: content, options: [], range: nsRange)

        for match in matches {
            if match.numberOfRanges >= 3,
               let urlRange = Range(match.range(at: 1), in: content),
               let titleRange = Range(match.range(at: 2), in: content) {
                let url = String(content[urlRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                var title = String(content[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                title = title.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                title = title.replacingOccurrences(of: "&amp;", with: "&")
                title = title.replacingOccurrences(of: "&quot;", with: "\"")
                title = title.replacingOccurrences(of: "&#39;", with: "'")
                title = title.replacingOccurrences(of: "&lt;", with: "<")
                title = title.replacingOccurrences(of: "&gt;", with: ">")

                if !url.isEmpty, !url.lowercased().hasPrefix("javascript:") {
                    results.append((title: title.isEmpty ? url : title, url: url))
                }
            }
        }
        return results
    }

    private func parseJSONBookmarks(_ data: Data) -> [(title: String, url: String)]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var results: [(title: String, url: String)] = []

        func extractChildren(from dict: [String: Any]) {
            // Chrome format: "url": "..." and "name": "..."
            if let url = dict["url"] as? String, let name = dict["name"] as? String {
                results.append((title: name, url: url))
            }
            // Firefox JSON format: "uri": "..." and "title": "..."
            if let uri = dict["uri"] as? String {
                let title = (dict["title"] as? String) ?? uri
                results.append((title: title, url: uri))
            }

            if let children = dict["children"] as? [[String: Any]] {
                for child in children {
                    extractChildren(from: child)
                }
            }
        }

        if let roots = json["roots"] as? [String: Any] {
            // Chrome JSON format
            for (_, rootVal) in roots {
                if let rootDict = rootVal as? [String: Any] {
                    extractChildren(from: rootDict)
                }
            }
        } else {
            // Firefox JSON backup format
            extractChildren(from: json)
        }

        return results.isEmpty ? nil : results
    }

    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let decoded = try? JSONDecoder().decode([Bookmark].self, from: data) {
            self.bookmarks = decoded
        } else {
            // Default developer bookmarks
            self.bookmarks = [
                Bookmark(title: "GitHub", url: "https://github.com"),
                Bookmark(title: "Hacker News", url: "https://news.ycombinator.com"),
                Bookmark(title: "Apple Developer", url: "https://developer.apple.com")
            ]
            saveBookmarks()
        }
    }

    private func saveBookmarks() {
        if let encoded = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(encoded, forKey: bookmarksKey)
        }
    }
}

// MARK: - Color Hex Conversion
extension Color {
    init(hex: String, fallback: Color = Color(nsColor: .windowBackgroundColor)) {
        var clean = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("#") {
            clean.removeFirst()
        }
        guard clean.count == 6, let intVal = UInt64(clean, radix: 16) else {
            self = fallback
            return
        }
        let r = Double((intVal >> 16) & 0xFF) / 255.0
        let g = Double((intVal >> 8) & 0xFF) / 255.0
        let b = Double(intVal & 0xFF) / 255.0
        self = Color(.sRGB, red: r, green: g, blue: b, opacity: 1.0)
    }
}

