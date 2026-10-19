//
//  Updater.swift
//  nomad
//
//  Native, zero-dependency in-place auto-updater for macOS.
//  Modelled after the atomic sibling-swap architecture of officecommun.com/search.
//

import Foundation
import AppKit
import Combine
import CryptoKit
import Security

/// Orchestrates background checking, downloading, verifying, and in-place swapping of Nomad releases.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// A release described by the remote feed.
    struct Release: Codable, Equatable {
        let version: String
        let build: Int
        let archive: URL
        var dmg: URL? = nil
        let sha256: String?
        var dmgSha256: String? = nil
        let notes: String?
        let minimumSystemVersion: String?

        var runsHere: Bool {
            guard let need = minimumSystemVersion else { return true }
            let parts = need.split(separator: ".").map { Int($0) ?? 0 }
            let least = OperatingSystemVersion(
                majorVersion: parts.count > 0 ? parts[0] : 0,
                minorVersion: parts.count > 1 ? parts[1] : 0,
                patchVersion: parts.count > 2 ? parts[2] : 0
            )
            return ProcessInfo.processInfo.isOperatingSystemAtLeast(least)
        }
    }

    /// Current progression state of the updater.
    enum Stage: Equatable {
        case none
        case checking
        case fetching(Release, progress: Double)
        case ready(Release)
        case waiting(Release)
        case failed(String)

        var isUpdating: Bool {
            switch self {
            case .checking, .fetching: return true
            default: return false
            }
        }
    }

    @Published private(set) var stage: Stage = .none
    @Published private(set) var checking: Bool = false
    @Published private(set) var lastChecked: Date? = nil
    @Published private(set) var statusMessage: String = ""

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    static var currentBuild: Int {
        Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 1
    }

    static let autoInstallKey = "nomad.update.autoInstall"
    static let lastCheckedKey = "nomad.update.lastChecked"

    var autoInstall: Bool {
        get {
            UserDefaults.standard.object(forKey: Self.autoInstallKey) as? Bool ?? true
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.autoInstallKey)
        }
    }

    /// Feed URL to query for new releases.
    static var feedURL: URL {
        if let env = ProcessInfo.processInfo.environment["NOMAD_FEED_URL"], let url = URL(string: env) {
            return url
        }
        if let overrideStr = UserDefaults.standard.string(forKey: "nomad.update.feedURL"), let url = URL(string: overrideStr) {
            return url
        }
        return URL(string: "https://raw.githubusercontent.com/tarunbtw/nomad/main/appcast.json")!
    }

    private var hourlyTimer: Timer?

    private init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            Swap.sweep()
        }
    }

    /// Called at launch: cleans any leftover swap, schedules hourly checks, and triggers initial lookup.
    func checkIfDue() {
        Swap.sweep()
        if hourlyTimer == nil {
            hourlyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.checkIfDueNow()
                }
            }
            hourlyTimer?.tolerance = 300
        }
        check { _ in }
    }

    private func checkIfDueNow() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckedKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 3000 else { return }
        check { _ in }
    }

    /// Manual user action (menu bar or settings).
    func checkByHand() {
        switch stage {
        case .ready(let next):
            statusMessage = "Nomad \(next.version) is ready — relaunch to use it"
            return
        case .fetching(let next, _):
            statusMessage = "Downloading Nomad \(next.version)..."
            return
        default:
            break
        }
        guard !checking else { return }
        statusMessage = "Checking for updates..."
        check { [weak self] found in
            guard let self = self else { return }
            if found == nil {
                self.statusMessage = "Nomad is up to date (\(Self.currentVersion))"
            }
        }
    }

    /// Fetches the feed and transitions stage.
    func check(then done: @escaping (Release?) -> Void = { _ in }) {
        guard !checking else { return }
        checking = true
        stage = .checking
        Task { [weak self] in
            guard let self = self else { return }
            let found = await Self.fetchFeed()
            self.checking = false
            self.lastChecked = Date()
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckedKey)

            guard let found = found, found.build > Self.currentBuild, found.runsHere else {
                if case .ready = self.stage {} else { self.stage = .none }
                done(nil)
                return
            }

            done(found)
            if self.autoInstall {
                self.take(found)
            } else {
                self.stage = .waiting(found)
                self.statusMessage = "Nomad \(found.version) is available"
            }
        }
    }

    /// Triggers download and atomic swap for an approved release.
    func install() {
        guard case .waiting(let release) = stage else { return }
        take(release)
    }

    private func take(_ release: Release) {
        switch stage {
        case .fetching, .ready: return
        default: break
        }
        stage = .fetching(release, progress: 0.0)
        statusMessage = "Downloading Nomad \(release.version)..."

        Task.detached(priority: .utility) { [weak self] in
            do {
                try await Swap.install(release) { progress in
                    Task { @MainActor [weak self] in
                        if case .fetching = self?.stage {
                            self?.stage = .fetching(release, progress: progress)
                        }
                    }
                }
                await MainActor.run { [weak self] in
                    self?.stage = .ready(release)
                    self?.statusMessage = "Nomad \(release.version) is ready — restart to use it"
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.stage = .failed(error.localizedDescription)
                    self?.statusMessage = "Update failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Replaces running app cleanly: spawns a background waiter that monitors our PID,
    /// then calls NSApp.terminate(nil). Once the old process exits, the waiter opens the new Nomad.app.
    func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let targetApp = Bundle.main.bundleURL.path
        let waiter = Process()
        waiter.executableURL = URL(fileURLWithPath: "/bin/sh")
        waiter.arguments = [
            "-c",
            "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; shift; exec \"$@\"",
            "sh",
            String(pid),
            "/usr/bin/open",
            targetApp
        ]
        try? waiter.run()
        NSApp.terminate(nil)
    }

    private static func fetchFeed() async -> Release? {
        var request = URLRequest(url: feedURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 15
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = json["version"] as? String,
              let build = (json["build"] as? Int) ?? Int(json["build"] as? String ?? ""),
              let urlStr = json["url"] as? String, let archiveURL = URL(string: urlStr)
        else {
            return nil
        }

        let sha = (json["sha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let dmgSha = (json["dmgSha256"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let notes = (json["notes"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let minSys = json["minimumSystemVersion"] as? String
        var dmgURL: URL? = nil
        if let dmgStr = json["dmg"] as? String {
            dmgURL = URL(string: dmgStr)
        }

        return Release(
            version: version,
            build: build,
            archive: archiveURL,
            dmg: dmgURL,
            sha256: (sha?.isEmpty == false) ? sha : nil,
            dmgSha256: (dmgSha?.isEmpty == false) ? dmgSha : nil,
            notes: (notes?.isEmpty == false) ? notes : nil,
            minimumSystemVersion: minSys
        )
    }
}

// MARK: - Atomic Swap Engine

private enum Swap {
    enum Refused: LocalizedError {
        case readOnly
        case download(String)
        case hashMismatch
        case archive(String)
        case plistCorrupt
        case wrongApp(expected: String, got: String)
        case notNewer(installed: Int, incoming: Int)
        case moveFailed(String)

        var errorDescription: String? {
            switch self {
            case .readOnly:
                return "The application directory is not writable (e.g. read-only volume or translocated)."
            case .download(let msg):
                return "Failed to download update archive: \(msg)"
            case .hashMismatch:
                return "Downloaded archive checksum (SHA-256) did not match feed manifest."
            case .archive(let msg):
                return "Failed to unpack application archive: \(msg)"
            case .plistCorrupt:
                return "Incoming application bundle Info.plist is unreadable or missing."
            case .wrongApp(let exp, let got):
                return "Incoming bundle identifier '\(got)' does not match expected '\(exp)'."
            case .notNewer(let inst, let inc):
                return "Incoming build (\(inc)) is not newer than currently installed build (\(inst))."
            case .moveFailed(let msg):
                return "Could not swap application bundles: \(msg)"
            }
        }
    }

    /// Running app bundle URL (e.g. /Applications/Nomad.app).
    static var target: URL { Bundle.main.bundleURL }

    /// Sibling bundle set aside during swap (e.g. /Applications/Nomad.app.old).
    static var aside: URL {
        target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + ".old")
    }

    /// Performs streaming download, checksum validation, extraction, integrity checking, and atomic swap.
    static func install(_ release: Updater.Release, onProgress: @escaping (Double) -> Void) async throws {
        let files = FileManager.default
        let appDir = target.deletingLastPathComponent()

        guard files.isWritableFile(atPath: appDir.path) else {
            throw Refused.readOnly
        }

        // Create scratch folder on the same volume as target to ensure atomic APFS renames
        let scratch = (try? files.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: target,
            create: true
        )) ?? files.temporaryDirectory.appendingPathComponent("nomad-update-\(release.build)-\(UUID().uuidString)", isDirectory: true)

        try files.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: scratch) }

        let zip = scratch.appendingPathComponent("Nomad.zip")
        try await download(release.archive, to: zip, onProgress: onProgress)

        // Validate SHA-256
        if let expected = release.sha256 {
            let actual = try digest(of: zip)
            guard actual == expected else {
                throw Refused.hashMismatch
            }
        }

        // Extract with ditto (preserves all permissions and extended attributes without Gatekeeper flags)
        let unpacked = scratch.appendingPathComponent("unpacked", isDirectory: true)
        try extract(zip, into: unpacked)

        guard let fresh = try files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else {
            throw Refused.archive("No .app bundle discovered inside archive")
        }

        // Verify incoming bundle
        try verify(fresh)

        // Perform the atomic rename swap
        try swap(fresh)
    }

    static func download(_ url: URL, to file: URL, onProgress: @escaping (Double) -> Void) async throws {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 120

        let (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw Refused.download("Server responded with HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }

        let expectedLength = response.expectedContentLength
        FileManager.default.createFile(atPath: file.path, contents: nil)
        guard let fileHandle = try? FileHandle(forWritingTo: file) else {
            throw Refused.download("Failed to open local destination for writing")
        }
        defer { try? fileHandle.close() }

        var written: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(64 * 1024)

        for try await byte in asyncBytes {
            buffer.append(byte)
            written += 1
            if buffer.count >= 64 * 1024 {
                try fileHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: true)
                if expectedLength > 0 {
                    onProgress(Double(written) / Double(expectedLength))
                }
            }
        }
        if !buffer.isEmpty {
            try fileHandle.write(contentsOf: buffer)
        }
        onProgress(1.0)
    }

    static func digest(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            sha.update(data: chunk)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func extract(_ zip: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zip.path, folder.path]
        ditto.standardOutput = FileHandle.nullDevice
        ditto.standardError = FileHandle.nullDevice
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            throw Refused.archive("ditto exited with status \(ditto.terminationStatus)")
        }
    }

    static func verify(_ bundle: URL) throws {
        let plistURL = bundle.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else {
            throw Refused.plistCorrupt
        }

        let currentId = Bundle.main.bundleIdentifier ?? "tarun.nomad"
        let incomingId = (info["CFBundleIdentifier"] as? String) ?? ""
        guard incomingId == currentId || currentId.isEmpty else {
            throw Refused.wrongApp(expected: currentId, got: incomingId)
        }

        let incomingBuild = Int(info["CFBundleVersion"] as? String ?? "") ?? 0
        guard incomingBuild > Updater.currentBuild else {
            throw Refused.notNewer(installed: Updater.currentBuild, incoming: incomingBuild)
        }
    }

    static func swap(_ fresh: URL) throws {
        let files = FileManager.default
        sweep()
        guard !files.fileExists(atPath: aside.path) else {
            throw Refused.moveFailed("Stale .old directory could not be cleared")
        }

        do {
            try files.moveItem(at: target, to: aside)
        } catch {
            throw Refused.moveFailed("Could not move current bundle aside: \(error.localizedDescription)")
        }

        do {
            try files.moveItem(at: fresh, to: target)
        } catch {
            // Instant automatic rollback
            try? files.moveItem(at: aside, to: target)
            throw Refused.moveFailed("Could not place new bundle: \(error.localizedDescription)")
        }
    }

    /// Removes leftover .old sibling bundle from prior update once old process has exited.
    static func sweep() {
        let plistURL = aside.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = info["CFBundleIdentifier"] as? String,
              id == (Bundle.main.bundleIdentifier ?? "tarun.nomad")
        else {
            return
        }
        try? FileManager.default.removeItem(at: aside)
    }
}
