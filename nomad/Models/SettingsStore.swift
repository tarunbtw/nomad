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
        didSet { objectWillChange.send() }
    }

    @AppStorage("nomad.searchEngine") var searchEngine: String = "duckduckgo" {
        didSet { objectWillChange.send() }
    }

    // MARK: - Bookmarks State
    @Published var bookmarks: [Bookmark] = []

    private let bookmarksKey = "nomad.bookmarks.json"

    init() {
        loadBookmarks()
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
    func addBookmark(title: String, url: String) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanURL.isEmpty else { return }

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

