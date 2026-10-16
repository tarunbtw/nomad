//
//  DownloadManager.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import AppKit
import WebKit
import Combine

/// Represents an active or completed file download.
@MainActor
final class DownloadItem: NSObject, Identifiable, ObservableObject {
    let id: UUID = UUID()
    let originalURL: URL
    let date: Date = Date()
    
    @Published var suggestedFilename: String
    @Published var destinationURL: URL?
    @Published var progress: Double = 0.0
    @Published var totalBytes: Int64 = 0
    @Published var receivedBytes: Int64 = 0
    @Published var state: DownloadState = .downloading
    @Published var errorMessage: String? = nil

    enum DownloadState: String, Equatable {
        case downloading = "Downloading"
        case completed = "Completed"
        case failed = "Failed"
        case cancelled = "Cancelled"
    }

    weak var manager: DownloadManager?

    var formattedSize: String {
        if totalBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        } else if receivedBytes > 0 {
            return ByteCountFormatter.string(fromByteCount: receivedBytes, countStyle: .file)
        }
        return ""
    }

    init(originalURL: URL, suggestedFilename: String, manager: DownloadManager) {
        self.originalURL = originalURL
        self.suggestedFilename = suggestedFilename.isEmpty ? "download" : suggestedFilename
        self.manager = manager
        super.init()
    }

    func cancel() {
        manager?.cancel(item: self)
    }
}

/// Central manager for WebKit downloads and macOS security quarantine tagging.
@MainActor
final class DownloadManager: NSObject, ObservableObject, WKDownloadDelegate {
    static let shared = DownloadManager()

    @Published private(set) var downloads: [DownloadItem] = []
    
    /// Strongly retains active WKDownload instances so ARC does not deallocate them during transfer.
    private var retainedDownloads: [ObjectIdentifier: WKDownload] = [:]
    private var progressObservers: [ObjectIdentifier: [NSKeyValueObservation]] = [:]

    var activeDownloads: [DownloadItem] {
        downloads.filter { $0.state == .downloading }
    }
    
    var hasActiveDownloads: Bool {
        !activeDownloads.isEmpty
    }

    var overallProgress: Double {
        let active = activeDownloads
        guard !active.isEmpty else { return 0 }
        let total = active.reduce(0.0) { $0 + $1.progress }
        return total / Double(active.count)
    }

    var downloadsDirectory: URL {
        let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
        return folder.resolvingSymlinksInPath()
    }

    var displayPath: String {
        downloadsDirectory.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    /// Explicitly maps each WKDownload to its DownloadItem so state and progress never cross-talk.
    private var downloadItems: [ObjectIdentifier: DownloadItem] = [:]

    private override init() {
        super.init()
    }

    /// Registers a WKDownload, strongly retaining it and monitoring progress.
    func register(_ download: WKDownload, from url: URL, suggestedFilename: String = "download") {
        download.delegate = self
        let key = ObjectIdentifier(download)
        retainedDownloads[key] = download

        let cleanName = (suggestedFilename.isEmpty ? (url.lastPathComponent.isEmpty ? "download" : url.lastPathComponent) : suggestedFilename)
        let item = DownloadItem(originalURL: url, suggestedFilename: cleanName, manager: self)
        downloadItems[key] = item
        downloads.insert(item, at: 0)

        // Observe live progress from WebKit's NSProgress
        let p = download.progress
        var observations: [NSKeyValueObservation] = []

        observations.append(p.observe(\.fractionCompleted, options: [.initial, .new]) { [weak item] prog, _ in
            Task { @MainActor [weak item] in
                guard let item, item.state == .downloading else { return }
                item.progress = prog.fractionCompleted
                item.receivedBytes = prog.completedUnitCount
                item.totalBytes = prog.totalUnitCount
            }
        })

        progressObservers[key] = observations
    }

    // MARK: - WKDownloadDelegate

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let key = ObjectIdentifier(download)
        let safeFilename = sanitizeFilename(suggestedFilename)
        
        // Ensure ~/Downloads directory exists
        try? FileManager.default.createDirectory(at: downloadsDirectory, withIntermediateDirectories: true)
        
        let destination = uniqueDestinationURL(for: safeFilename)
        
        if let item = downloadItems[key] {
            item.suggestedFilename = safeFilename
            item.destinationURL = destination
        }
        
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)
        let item = downloadItems[key]
        defer {
            retainedDownloads.removeValue(forKey: key)
            downloadItems.removeValue(forKey: key)
            progressObservers.removeValue(forKey: key)
        }

        if let item = item {
            item.progress = 1.0
            item.state = .completed
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        let item = downloadItems[key]
        defer {
            retainedDownloads.removeValue(forKey: key)
            downloadItems.removeValue(forKey: key)
            progressObservers.removeValue(forKey: key)
        }

        if let item = item {
            item.state = .failed
            item.errorMessage = error.localizedDescription
        }
    }

    // MARK: - Actions

    func cancel(item: DownloadItem) {
        item.state = .cancelled
        if let key = downloadItems.first(where: { $0.value.id == item.id })?.key {
            retainedDownloads[key]?.cancel { _ in }
            retainedDownloads.removeValue(forKey: key)
            downloadItems.removeValue(forKey: key)
            progressObservers.removeValue(forKey: key)
        }
    }

    func showInFinder(_ item: DownloadItem) {
        guard let dest = item.destinationURL, FileManager.default.fileExists(atPath: dest.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([dest])
    }

    func openFile(_ item: DownloadItem) {
        guard let dest = item.destinationURL, FileManager.default.fileExists(atPath: dest.path) else { return }
        NSWorkspace.shared.open(dest)
    }

    func openDownloadsFolder() {
        NSWorkspace.shared.open(downloadsDirectory)
    }

    func removeDownload(_ item: DownloadItem) {
        cancel(item: item)
        downloads.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        downloads.removeAll { $0.state != .downloading }
    }


    // MARK: - Destination Disambiguation & Sanitization

    private func sanitizeFilename(_ filename: String) -> String {
        let raw = filename.isEmpty ? "download" : filename
        var clean = (raw as NSString).lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.isEmpty || clean == "." || clean == ".." || clean.hasPrefix(".") {
            clean = "download" + (clean.isEmpty ? "" : "_\(clean)")
        }
        return clean
    }

    private func uniqueDestinationURL(for filename: String) -> URL {
        let safeName = sanitizeFilename(filename)
        let base = downloadsDirectory.appendingPathComponent(safeName)
        if !FileManager.default.fileExists(atPath: base.path) {
            return base
        }

        let name = (safeName as NSString).deletingPathExtension
        let ext = (safeName as NSString).pathExtension
        var counter = 1
        
        while true {
            let candidateName = ext.isEmpty ? "\(name) (\(counter))" : "\(name) (\(counter)).\(ext)"
            let candidate = downloadsDirectory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            counter += 1
        }
    }
}
