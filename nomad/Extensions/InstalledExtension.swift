//
//  InstalledExtension.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import Foundation

/// Represents an installed WebExtension in Nomad.
/// Stored in ~/Library/Application Support/nomad/Extensions/installed.json
struct InstalledExtension: Codable, Identifiable, Equatable {
    /// 32-character Chrome extension ID (or SHA-256 derived ID for unpacked folders).
    let id: String
    /// Human-readable name from manifest.json.
    var name: String
    /// Extension version string.
    var version: String
    /// Whether the extension is currently active in WebKit.
    var enabled: Bool
    /// True if installed from the Chrome Web Store, false if unpacked local folder.
    var fromStore: Bool
    /// True if pinned to Nomad's top toolbar next to navigation controls.
    var pinned: Bool
    /// Declared manifest permissions (e.g. storage, alarms, declarativeNetRequest).
    var permissions: [String]
    /// Original file path if loaded unpacked from disk.
    var sourcePath: String?
    /// Relative path to extension action popup HTML (e.g. "popup.html") if declared.
    var popupPath: String?
    /// Relative path to options page HTML (e.g. "options.html") if declared.
    var optionsPath: String?
}
