//
//  URLParser.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import Foundation

/// Resolves user input into a navigable URL.
/// Converts valid addresses to URLs and falls back to a clean search query.
enum URLParser {
    private static let supportedSchemes: Set<String> = ["http", "https", "file", "about", "data"]
    private static let searchEngineURL = "https://duckduckgo.com/?q="

    /// Parses user-typed text into a destination URL.
    static func parse(_ input: String) -> URL {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return URL(string: "about:blank")!
        }

        // If it already starts with a recognized scheme, use it directly
        if let schemeRange = trimmed.range(of: "://") {
            let scheme = String(trimmed[..<schemeRange.lowerBound]).lowercased()
            if supportedSchemes.contains(scheme), let url = URL(string: trimmed) {
                return url
            }
        }

        // Handle about: or data: prefixes
        if trimmed.lowercased().hasPrefix("about:") || trimmed.lowercased().hasPrefix("data:") {
            if let url = URL(string: trimmed) { return url }
        }

        // Check if text looks like a host or IP (e.g. "github.com", "localhost:3000", "127.0.0.1")
        if looksLikeHost(trimmed) {
            let scheme = isLocalHost(trimmed) ? "http://" : "https://"
            if let url = URL(string: scheme + trimmed) {
                return url
            }
        }

        // Otherwise, treat as a search query
        let encodedQuery = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed
        return URL(string: "\(searchEngineURL)\(encodedQuery)")!
    }

    /// Checks if a string looks like a web address or domain name rather than search keywords.
    private static func looksLikeHost(_ string: String) -> Bool {
        // Discard strings with spaces or containing @
        guard !string.contains(" "), !string.contains("@") else { return false }

        let hostPart = string.components(separatedBy: "/").first ?? string
        let cleanHost = hostPart.components(separatedBy: ":").first ?? hostPart

        if isLocalHost(cleanHost) { return true }

        // Must have at least one dot with valid characters and a common TLD structure
        let parts = cleanHost.components(separatedBy: ".")
        guard parts.count >= 2, let tld = parts.last else { return false }

        // Valid TLD check (letters only, at least 2 characters)
        let tldRegex = "^[a-zA-Z]{2,63}$"
        return tld.range(of: tldRegex, options: .regularExpression) != nil
    }

    /// Detects local development environments (localhost, 127.0.0.1, etc.)
    private static func isLocalHost(_ string: String) -> Bool {
        let lower = string.lowercased()
        let hostPart = lower.components(separatedBy: ":").first ?? lower
        return hostPart == "localhost"
            || hostPart.hasSuffix(".local")
            || hostPart.hasSuffix(".localhost")
            || hostPart == "127.0.0.1"
            || hostPart == "0.0.0.0"
            || hostPart.hasPrefix("192.168.")
            || hostPart.hasPrefix("10.")
    }
}
