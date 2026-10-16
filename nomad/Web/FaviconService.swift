//
//  FaviconService.swift
//  nomad
//
//  Created by tarun on 10/11/26.
//

import AppKit

/// High-performance thread-safe favicon service for fetching and caching website favicons.
@MainActor
final class FaviconService {
    static let shared = FaviconService()

    private let memoryCache = NSCache<NSString, NSImage>()
    private var inFlightTasks: [String: Task<NSImage?, Never>] = [:]

    private init() {
        memoryCache.countLimit = 250
    }

    /// Synchronously returns cached favicon if available.
    func cachedFavicon(for host: String) -> NSImage? {
        let cleaned = cleanHost(host)
        return memoryCache.object(forKey: cleaned as NSString)
    }

    /// Fetches favicon from a direct icon URL (e.g. extracted from HTML link rel="icon").
    func loadFavicon(fromDirectURL iconURL: URL, host: String) async -> NSImage? {
        let cleanedHost = cleanHost(host)
        var request = URLRequest(url: iconURL)
        request.timeoutInterval = 6

        if let (data, response) = try? await URLSession.shared.data(for: request),
           let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
           let image = NSImage(data: data), image.isValid {
            memoryCache.setObject(image, forKey: cleanedHost as NSString)
            return image
        }
        return nil
    }

    /// Fetches favicon for a given URL asynchronously with multi-source fallback.
    func loadFavicon(for url: URL?) async -> NSImage? {
        guard let url = url, let host = url.host, !host.isEmpty else { return nil }
        
        let cleanedHost = cleanHost(host)
        
        if let cached = memoryCache.object(forKey: cleanedHost as NSString) {
            return cached
        }

        // Avoid duplicate concurrent fetches for the same host
        if let existing = inFlightTasks[cleanedHost] {
            return await existing.value
        }

        let isPrivate = isPrivateOrLocalHost(cleanedHost)

        let task = Task<NSImage?, Never> {
            // Strategy 1: High-res DuckDuckGo favicon API (global CDN, 32x32 ico) - public domains only
            if !isPrivate, let ddgURL = URL(string: "https://icons.duckduckgo.com/ip3/\(cleanedHost).ico") {
                var req = URLRequest(url: ddgURL)
                req.timeoutInterval = 4
                if let (data, response) = try? await URLSession.shared.data(for: req),
                   let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                   let image = NSImage(data: data), image.isValid {
                    return image
                }
            }

            // Strategy 2: Google Favicon API fallback - public domains only
            if !isPrivate, let googleURL = URL(string: "https://www.google.com/s2/favicons?domain=\(cleanedHost)&sz=64") {
                var req = URLRequest(url: googleURL)
                req.timeoutInterval = 4
                if let (data, response) = try? await URLSession.shared.data(for: req),
                   let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                   let image = NSImage(data: data), image.isValid {
                    return image
                }
            }

            // Strategy 3: Direct /favicon.ico fallback
            if let scheme = url.scheme,
               let directURL = URL(string: "\(scheme)://\(host)/favicon.ico") {
                var req = URLRequest(url: directURL)
                req.timeoutInterval = 4
                if let (data, response) = try? await URLSession.shared.data(for: req),
                   let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                   let image = NSImage(data: data), image.isValid {
                    return image
                }
            }

            return nil
        }

        inFlightTasks[cleanedHost] = task
        let image = await task.value
        inFlightTasks.removeValue(forKey: cleanedHost)

        if let image = image {
            memoryCache.setObject(image, forKey: cleanedHost as NSString)
        }

        return image
    }

    private func cleanHost(_ host: String) -> String {
        var h = host.lowercased()
        if h.hasPrefix("www.") {
            h.removeFirst(4)
        }
        return h
    }

    private func isPrivateOrLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "127.0.0.1" || lower == "::1" { return true }
        if lower.hasSuffix(".local") || lower.hasSuffix(".internal") || lower.hasSuffix(".lan") || lower.hasSuffix(".home") || lower.hasSuffix(".arpa") { return true }
        if !lower.contains(".") { return true }
        if lower.starts(with: "192.168.") || lower.starts(with: "10.") || lower.starts(with: "127.") { return true }
        if lower.starts(with: "172.") {
            let parts = lower.split(separator: ".")
            if parts.count >= 2, let second = Int(parts[1]), (16...31).contains(second) {
                return true
            }
        }
        return false
    }
}
