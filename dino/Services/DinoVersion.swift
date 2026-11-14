//
//  DinoVersion.swift
//  dino
//
//  Single source of truth for Dino version and build metadata across the app, daemon, and CLI.
//

import Foundation

public enum DinoVersion {
    public static let appName = "Dino"
    public static let version = "0.43"
    public static let build = "1"

    /// Resolves the actual runtime version string, inspecting the enclosing bundle if running from a symlinked CLI binary.
    public static var currentVersion: String {
        if let infoVer = resolvedBundle?.infoDictionary?["CFBundleShortVersionString"] as? String, !infoVer.isEmpty, infoVer != "0.1" {
            return infoVer
        }
        return version
    }

    /// Resolves the actual runtime build integer.
    public static var currentBuild: Int {
        if let buildStr = resolvedBundle?.infoDictionary?["CFBundleVersion"] as? String, let b = Int(buildStr) {
            return b
        }
        return Int(build) ?? 1
    }

    /// Resolves the bundle even when the CLI is executed via symlink (e.g. /opt/homebrew/bin/dino -> /Applications/Dino.app/Contents/MacOS/dino).
    public static var resolvedBundle: Bundle? {
        if let dict = Bundle.main.infoDictionary, dict["CFBundleShortVersionString"] != nil {
            return Bundle.main
        }
        // Try resolving real executable path and its enclosing .app bundle
        guard !CommandLine.arguments.isEmpty else { return Bundle.main }
        let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        // Dino.app/Contents/MacOS/dino -> 3 levels up is Dino.app
        let appBundleURL = execURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: appBundleURL.appendingPathComponent("Contents/Info.plist").path) {
            return Bundle(url: appBundleURL)
        }
        if let fallback = Bundle(url: URL(fileURLWithPath: "/Applications/Dino.app")), fallback.infoDictionary?["CFBundleShortVersionString"] != nil {
            return fallback
        }
        if let legacy = Bundle(url: URL(fileURLWithPath: "/Applications/Dino.app")), legacy.infoDictionary?["CFBundleShortVersionString"] != nil {
            return legacy
        }
        return Bundle.main
    }
}
