//
//  URLParser.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import Foundation
import WebKit

/// Resolves user input into a navigable URL.
/// Handles standard web domains, internal nomad:// schemes, and fallback search queries.
enum URLParser {
    private static let supportedSchemes: Set<String> = ["http", "https", "file", "about", "data", "nomad", "chrome-extension", "webkit-extension"]

    /// Parses user-typed text into a destination URL.
    @MainActor
    static func parse(_ input: String) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return URL(string: "about:blank")!
        }

        let lower = trimmed.lowercased()

        // Direct internal schemes (nomad://settings, redirects nomad://tune to settings)
        if lower == "settings" || lower == "nomad://settings" || lower == "tune" || lower == "nomad://tune" {
            return URL(string: "nomad://settings")!
        }

        // Direct extension ID check: if input matches an installed extension ID, navigate to its default page
        if let ext = ExtensionManager.shared.installed.first(where: { $0.id == trimmed }),
           let context = ExtensionManager.shared.contexts[ext.id],
           let url = ExtensionManager.defaultPageURL(for: context) {
            return url
        }

        // If it starts with a recognized scheme (including nomad://), use it directly
        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
            if supportedSchemes.contains(scheme), let url = URL(string: trimmed) {
                return url
            }
        }

        // Handle about: or data: prefixes
        if lower.hasPrefix("about:") || lower.hasPrefix("data:") {
            if let url = URL(string: trimmed) { return url }
        }

        // Direct local filesystem file paths
        if trimmed.hasPrefix("/") && FileManager.default.fileExists(atPath: trimmed) {
            return URL(fileURLWithPath: trimmed)
        }

        // Check if text looks like a host or IP (e.g. "github.com", "localhost:3000", "127.0.0.1")
        if looksLikeHost(trimmed) {
            let scheme = trimmed.isLocalOrPrivateHost ? "http://" : "https://"
            if let url = URL(string: scheme + trimmed) {
                return url
            }
        }

        // Otherwise, treat as a search query using the configured search engine
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        let searchBase = SettingsStore.shared.searchEngineBaseURL
        return URL(string: "\(searchBase)\(encodedQuery)")!
    }

    /// Checks if a string looks like a web address or domain name rather than search keywords.
    private static func looksLikeHost(_ string: String) -> Bool {
        // Discard strings with spaces or containing @
        guard !string.contains(" "), !string.contains("@") else { return false }

        let cleanHost = URL(string: "http://\(string)")?.host ?? string

        if cleanHost.isLocalOrPrivateHost { return true }

        // Must have at least one dot with valid characters and a common TLD structure
        let parts = cleanHost.components(separatedBy: ".")
        guard parts.count >= 2, let tld = parts.last else { return false }

        // Valid TLD check (letters only, 2 to 63 characters)
        return tld.count >= 2 && tld.count <= 63 && tld.allSatisfy { $0.isASCII && $0.isLetter }
    }
}

extension String {
    /// Detects local development environments and private networks (localhost, 127.0.0.1, 192.168.x, etc.)
    var isLocalOrPrivateHost: Bool {
        let lower = self.lowercased()
        let hostPart = lower.components(separatedBy: ":").first ?? lower
        if hostPart == "localhost" || hostPart == "127.0.0.1" || hostPart == "::1" || hostPart == "0.0.0.0" { return true }
        if hostPart.hasSuffix(".local") || hostPart.hasSuffix(".localhost") || hostPart.hasSuffix(".internal") || hostPart.hasSuffix(".lan") || hostPart.hasSuffix(".home") || hostPart.hasSuffix(".arpa") { return true }
        if !hostPart.contains(".") { return true }
        if hostPart.hasPrefix("192.168.") || hostPart.hasPrefix("10.") || hostPart.hasPrefix("127.") { return true }
        if hostPart.hasPrefix("172.") {
            let parts = hostPart.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
