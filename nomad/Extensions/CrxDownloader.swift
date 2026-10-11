//
//  CrxDownloader.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import Foundation
import CryptoKit

/// Downloads and unpacks Chrome extensions (.crx) directly from the Chrome Web Store,
/// or loads unpacked extension directories for local development.
enum CrxDownloader {
    enum DownloadError: LocalizedError {
        case invalidIDOrURL
        case networkError(Int)
        case emptyResponse
        case invalidCRXFormat
        case unpackFailed
        case missingManifest

        var errorDescription: String? {
            switch self {
            case .invalidIDOrURL:
                return "The provided link or ID is not a valid Chrome Web Store extension."
            case .networkError(let code):
                return "The Chrome Web Store returned HTTP error \(code)."
            case .emptyResponse:
                return "The Chrome Web Store did not return a package for this extension ID."
            case .invalidCRXFormat:
                return "The downloaded file is not a valid Chrome extension package."
            case .unpackFailed:
                return "Failed to extract the extension ZIP package."
            case .missingManifest:
                return "The package does not contain a valid manifest.json file."
            }
        }
    }

    /// Extract 32-letter Chrome Web Store extension ID (characters a-p).
    static func extractID(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"(?<![a-z])([a-p]{32})(?![a-z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
              let range = Range(match.range(at: 1), in: trimmed) else {
            return nil
        }
        return String(trimmed[range]).lowercased()
    }

    /// Generates a stable 32-character extension ID for an unpacked local folder,
    /// matching Chromium's convention (first 16 bytes of SHA-256, mapped to letters a-p).
    static func unpackedID(for folderURL: URL) -> String {
        let canonicalPath = folderURL.standardizedFileURL.path
        let hash = SHA256.hash(data: Data(canonicalPath.utf8))
        let prefix16 = Array(hash.prefix(16))
        return prefix16.flatMap { byte in
            [
                Character(UnicodeScalar(97 + (byte >> 4))),
                Character(UnicodeScalar(97 + (byte & 0x0F)))
            ]
        }.reduce("") { $0 + String($1) }
    }

    /// Downloads and extracts an extension package from the Chrome Web Store.
    static func downloadAndUnpack(id: String, destinationFolder: URL) async throws -> InstalledExtension {
        var components = URLComponents(string: "https://clients2.google.com/service/update2/crx")!
        components.queryItems = [
            URLQueryItem(name: "response", value: "redirect"),
            URLQueryItem(name: "prodversion", value: "130.0.0.0"),
            URLQueryItem(name: "acceptformat", value: "crx3"),
            URLQueryItem(name: "x", value: "id=\(id)&installsource=ondemand&uc")
        ]
        
        guard let downloadURL = components.url else {
            throw DownloadError.invalidIDOrURL
        }

        var request = URLRequest(url: downloadURL)
        request.timeoutInterval = 60
        let (data, response) = try await URLSession.shared.data(for: request)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError.networkError(http.statusCode)
        }
        guard !data.isEmpty else {
            throw DownloadError.emptyResponse
        }

        // Verify CRX3 magic header ("Cr24")
        let bytes = [UInt8](data)
        guard bytes.count > 16, Array(bytes[0..<4]) == Array("Cr24".utf8) else {
            throw DownloadError.invalidCRXFormat
        }

        // Extract header length (little-endian uint32 at offset 8)
        let headerSize = Int(UInt32(bytes[8]) | UInt32(bytes[9]) << 8 | UInt32(bytes[10]) << 16 | UInt32(bytes[11]) << 24)
        guard 12 + headerSize < bytes.count else {
            throw DownloadError.invalidCRXFormat
        }

        let zipData = Data(bytes[(12 + headerSize)...])
        try unpackZip(zipData, into: destinationFolder)

        let manifest = try parseManifest(at: destinationFolder)
        return InstalledExtension(
            id: id,
            name: manifest.name,
            version: manifest.version,
            enabled: true,
            fromStore: true,
            pinned: true,
            permissions: manifest.permissions,
            sourcePath: nil,
            popupPath: manifest.popupPath,
            optionsPath: manifest.optionsPath
        )
    }

    /// Imports an unpacked developer extension folder into Nomad.
    static func installUnpacked(folderURL: URL, destinationFolder: URL) async throws -> InstalledExtension {
        let manifest = try parseManifest(at: folderURL)
        let id = unpackedID(for: folderURL)
        let targetDir = destinationFolder.appendingPathComponent(id, isDirectory: true)

        let fm = FileManager.default
        try? fm.removeItem(at: targetDir)
        try fm.createDirectory(at: targetDir.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: folderURL, to: targetDir)

        return InstalledExtension(
            id: id,
            name: manifest.name,
            version: manifest.version,
            enabled: true,
            fromStore: false,
            pinned: true,
            permissions: manifest.permissions,
            sourcePath: folderURL.path,
            popupPath: manifest.popupPath,
            optionsPath: manifest.optionsPath
        )
    }

    /// Unpacks ZIP data using native macOS `/usr/bin/ditto`.
    private static func unpackZip(_ zipData: Data, into destination: URL) throws {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory.appendingPathComponent("nomad-crx-\(UUID().uuidString)")
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempDir) }

        let zipFile = tempDir.appendingPathComponent("extension.zip")
        try zipData.write(to: zipFile)

        let outDir = tempDir.appendingPathComponent("unpacked", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zipFile.path, outDir.path]
        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              fm.fileExists(atPath: outDir.appendingPathComponent("manifest.json").path) else {
            throw DownloadError.unpackFailed
        }

        try? fm.removeItem(at: destination)
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: outDir, to: destination)
    }

    /// Parses manifest.json from an extension folder.
    static func parseManifest(at folder: URL) throws -> (name: String, version: String, permissions: [String], popupPath: String?, optionsPath: String?) {
        let manifestFile = folder.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: manifestFile),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DownloadError.missingManifest
        }

        var name = (json["name"] as? String) ?? "Unnamed Extension"
        // If manifest uses localized __MSG_name__, look up in _locales/en/messages.json
        if name.hasPrefix("__MSG_") && name.hasSuffix("__") {
            let key = String(name.dropFirst(6).dropLast(2))
            let localesFile = folder.appendingPathComponent("_locales/en/messages.json")
            if let lData = try? Data(contentsOf: localesFile),
               let lJson = (try? JSONSerialization.jsonObject(with: lData)) as? [String: Any],
               let entry = lJson[key] as? [String: Any],
               let message = entry["message"] as? String {
                name = message
            }
        }

        let version = (json["version"] as? String) ?? "1.0.0"
        let permissions = (json["permissions"] as? [String]) ?? []

        // Extract action popup path
        var popupPath: String? = nil
        if let action = json["action"] as? [String: Any], let popup = action["default_popup"] as? String {
            popupPath = popup
        } else if let browserAction = json["browser_action"] as? [String: Any], let popup = browserAction["default_popup"] as? String {
            popupPath = popup
        }

        // Extract options page path
        var optionsPath: String? = nil
        if let optionsPage = json["options_page"] as? String {
            optionsPath = optionsPage
        } else if let optionsUI = json["options_ui"] as? [String: Any], let page = optionsUI["page"] as? String {
            optionsPath = page
        }

        return (name, version, permissions, popupPath, optionsPath)
    }
}
