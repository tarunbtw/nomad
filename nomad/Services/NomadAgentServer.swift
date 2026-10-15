//
//  NomadAgentServer.swift
//  nomad
//
//  Created by tarun on 12/10/26.
//

import Foundation
import Network
import AppKit
import Combine
import WebKit

/// Embedded lightweight local API server for Nomad using Apple's native Network.framework.
/// Binds strictly to 127.0.0.1:9222 with zero third-party dependencies, 0% idle CPU, and automatic socket cleanup.
@MainActor
final class NomadAgentServer: ObservableObject {
    static let shared = NomadAgentServer()

    static var defaultPort: UInt16 {
        if let envStr = ProcessInfo.processInfo.environment["NOMAD_AGENT_PORT"],
           let p = UInt16(envStr) {
            return p
        }
        return 9222
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = NomadAgentServer.defaultPort
    @Published private(set) var requestCount: Int = 0

    /// Secure local authentication token loaded from ~/.nomad/agent-token or NOMAD_TOKEN environment variable.
    let token: String = NomadAgentServer.loadOrCreateAgentToken()

    weak var store: BrowserStore?

    private var listener: NWListener?
    nonisolated private let serverQueue = DispatchQueue(label: "nomad.agent.server", qos: .userInitiated)

    private init() {}

    /// Loads an existing agent token from ~/.nomad/agent-token or generates a new cryptographically secure token.
    private static func loadOrCreateAgentToken() -> String {
        if let envToken = ProcessInfo.processInfo.environment["NOMAD_TOKEN"], !envToken.isEmpty {
            return envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let fileManager = FileManager.default
        let homeDir = fileManager.homeDirectoryForCurrentUser
        let nomadDir = homeDir.appendingPathComponent(".nomad", isDirectory: true)
        let tokenFile = nomadDir.appendingPathComponent("agent-token")

        if let existing = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }

        try? fileManager.createDirectory(at: nomadDir, withIntermediateDirectories: true, attributes: [
            .posixPermissions: 0o700
        ])

        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
            + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

        try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        return token
    }

    /// Starts the local agent server (default: NOMAD_AGENT_PORT or 9222).
    @MainActor
    func start(port: UInt16? = nil, store: BrowserStore? = nil) {
        if let store = store {
            self.store = store
        }
        guard !isRunning else { return }
        self.port = port ?? Self.defaultPort

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = false
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback

            guard let endpointPort = NWEndpoint.Port(rawValue: self.port) else {
                print("⚠️ [NomadAgentServer] Invalid port: \(self.port)")
                return
            }

            let newListener = try NWListener(using: params, on: endpointPort)

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self.isRunning = true
                        print("🟢 [NomadAgentServer] Listening on http://127.0.0.1:\(self.port) (Bearer auth enabled)")
                    case .failed(let error):
                        print("🔴 [NomadAgentServer] Failed with error: \(error)")
                        self.stop()
                    case .cancelled:
                        self.isRunning = false
                        print("⚪️ [NomadAgentServer] Stopped.")
                    default:
                        break
                    }
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                self.handleIncomingConnection(connection)
            }

            self.listener = newListener
            newListener.start(queue: serverQueue)
        } catch {
            print("⚠️ [NomadAgentServer] Could not initialize NWListener: \(error)")
        }
    }

    /// Stops the server and cleanly releases all sockets and connections.
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - HTTP Request Handling (Runs on serverQueue)

    nonisolated private func handleIncomingConnection(_ connection: NWConnection) {
        // Enforce loopback check on incoming peer endpoint to prevent interface leakage
        if case .hostPort(let host, _) = connection.endpoint {
            let hostStr = "\(host)"
            if hostStr != "127.0.0.1" && hostStr != "::1" && hostStr != "localhost" {
                print("🛡️ [NomadAgentServer] Rejecting non-loopback connection from: \(hostStr)")
                connection.cancel()
                return
            }
        }

        connection.start(queue: serverQueue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, _, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if let data = data, !data.isEmpty {
                self.processRequest(data: data, connection: connection)
            } else {
                connection.cancel()
            }
            if let error = error {
                print("⚠️ [NomadAgentServer] Connection error: \(error)")
                connection.cancel()
            }
        }
    }

    nonisolated private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid UTF-8 payload\"}")
            return
        }

        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first, !requestLine.isEmpty else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Empty request\"}")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed HTTP request line\"}")
            return
        }

        let method = parts[0].uppercased()
        let fullPath = parts[1]
        let path = fullPath.components(separatedBy: "?").first ?? fullPath
        let queryString = fullPath.contains("?") ? String(fullPath.split(separator: "?", maxSplits: 1).last ?? "") : ""

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            if let colonIdx = line.firstIndex(of: ":") {
                let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces).lowercased()
                let val = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                headers[key] = val
            }
        }

        // Origin Header Guard: block drive-by CSRF / DNS rebinding from arbitrary web browsers
        if let origin = headers["origin"], !origin.isEmpty {
            let allowedOrigins = ["http://127.0.0.1", "http://localhost", "nomad://"]
            let isAllowed = allowedOrigins.contains { origin.starts(with: $0) }
            if !isAllowed {
                sendResponse(connection: connection, status: "403 Forbidden", body: "{\"error\":\"Cross-origin request rejected from \(origin)\"}", origin: origin)
                return
            }
        }

        // Extract body if present
        var bodyData: Data? = nil
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            let bodySub = requestString[bodyRange.upperBound...]
            bodyData = bodySub.data(using: .utf8)
        }

        Task { @MainActor in
            self.requestCount += 1
            await self.routeRequest(method: method, path: path, queryString: queryString, headers: headers, bodyData: bodyData, connection: connection)
        }
    }

    @MainActor
    private func routeRequest(method: String, path: String, queryString: String, headers: [String: String], bodyData: Data?, connection: NWConnection) async {
        let origin = headers["origin"]

        guard let store = self.store else {
            sendResponse(connection: connection, status: "503 Service Unavailable", body: "{\"error\":\"BrowserStore not connected\"}", origin: origin)
            return
        }

        // Handle CORS Preflight
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "204 No Content", body: "", origin: origin)
            return
        }

        // Token Auth check (bypassed if NOMAD_DISABLE_AUTH=1 in environment)
        let isPublicEndpoint = (method == "GET" && (path == "/" || path == "/status"))
        let authDisabled = ProcessInfo.processInfo.environment["NOMAD_DISABLE_AUTH"] == "1"
        if !isPublicEndpoint && !authDisabled {
            let authHeader = headers["authorization"] ?? ""
            var providedToken: String? = nil
            if authHeader.lowercased().starts(with: "bearer ") {
                providedToken = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if let customHeader = headers["x-nomad-token"] {
                providedToken = customHeader.trimmingCharacters(in: .whitespaces)
            } else if queryString.contains("token=") {
                let qItems = queryString.components(separatedBy: "&")
                for item in qItems {
                    let kv = item.components(separatedBy: "=")
                    if kv.count == 2 && kv[0] == "token" {
                        providedToken = kv[1]
                    }
                }
            }

            guard let tok = providedToken, tok == self.token else {
                sendResponse(connection: connection, status: "401 Unauthorized", body: "{\"error\":\"Unauthorized: valid Bearer token required in Authorization header or ~/.nomad/agent-token\"}", origin: origin)
                return
            }
        }

        func resolveTab(id: String?) -> Tab? {
            if let id = id, let uuid = UUID(uuidString: id) {
                return store.tabs.first(where: { $0.id == uuid })
            }
            return store.activeTab
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/status"):
            let capabilities: [String: Any] = [
                "waitModes": ["stability", "selector", "timeout", "networkidle", "navigation", "url"],
                "actions": ["click", "hover", "type", "clear", "press", "selectOption", "scroll", "drag", "highlight"],
                "screenshot": ["full", "labeled", "clip", "elementId"],
                "evaluateWorlds": ["page", "isolated"],
                "snapshotModes": ["text", "json"],
                "cookies": ["get", "set", "clear"],
                "console": ["log", "warn", "error"],
                "network": ["fetch", "xhr", "status", "timing"]
            ]
            let statusObj: [String: Any] = [
                "nomad": "active",
                "version": "1.0",
                "port": self.port,
                "tabsCount": store.tabs.count,
                "activeTabId": store.activeTabId?.uuidString ?? "",
                "activeURL": store.activeTab?.url?.absoluteString ?? "",
                "activeTitle": store.activeTab?.title ?? "",
                "lastDialog": (store.activeTab?.lastDialog as Any?) ?? NSNull(),
                "capabilities": capabilities
            ]
            sendJSON(connection: connection, object: statusObj, origin: origin)

        case ("GET", "/tabs"):
            let tabsList = store.tabs.map { tab in
                [
                    "id": tab.id.uuidString,
                    "title": tab.title,
                    "url": tab.url?.absoluteString ?? "",
                    "isIncognito": tab.isIncognito,
                    "isActive": tab.id == store.activeTabId,
                    "isLoading": tab.isLoading
                ] as [String: Any]
            }
            sendJSON(connection: connection, object: ["tabs": tabsList], origin: origin)

        case ("POST", "/tabs/new"):
            var targetURL: URL? = nil
            var select = true
            var isIncognito = false

            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let urlStr = json["url"] as? String, let parsed = URL(string: urlStr) {
                    targetURL = parsed
                }
                if let sel = json["select"] as? Bool { select = sel }
                if let inc = json["isIncognito"] as? Bool { isIncognito = inc }
            }

            let newTab = store.newTab(url: targetURL, isIncognito: isIncognito, select: select)
            sendJSON(connection: connection, object: [
                "success": true,
                "tabId": newTab.id.uuidString,
                "title": newTab.title,
                "url": newTab.url?.absoluteString ?? ""
            ], origin: origin)

        case ("POST", "/tabs/switch"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\"}", origin: origin)
                return
            }
            guard store.tabs.contains(where: { $0.id == id }) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found: \(id.uuidString)\"}", origin: origin)
                return
            }
            store.selectTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "activeTabId": id.uuidString], origin: origin)

        case ("POST", "/tabs/close"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\"}", origin: origin)
                return
            }
            guard store.tabs.contains(where: { $0.id == id }) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found: \(id.uuidString)\"}", origin: origin)
                return
            }
            store.closeTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "closedTabId": id.uuidString], origin: origin)

        case ("POST", "/navigate"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing body in /navigate\"}", origin: origin)
                return
            }
            let action = (json["action"] as? String)?.lowercased()
            switch action {
            case "back":
                if !activeTab.canGoBack {
                    sendJSON(connection: connection, object: ["success": false, "action": "back", "message": "Cannot go back: navigation history is empty"], origin: origin)
                } else {
                    store.goBack()
                    sendJSON(connection: connection, object: ["success": true, "action": "back"], origin: origin)
                }
            case "forward":
                if !activeTab.canGoForward {
                    sendJSON(connection: connection, object: ["success": false, "action": "forward", "message": "Cannot go forward: navigation history is empty"], origin: origin)
                } else {
                    store.goForward()
                    sendJSON(connection: connection, object: ["success": true, "action": "forward"], origin: origin)
                }
            case "reload":
                store.reload()
                sendJSON(connection: connection, object: ["success": true, "action": "reload"], origin: origin)
            default:
                guard let urlStr = json["url"] as? String, let url = URL(string: urlStr), let scheme = url.scheme?.lowercased() else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid url in body\"}", origin: origin)
                    return
                }
                if scheme == "javascript" {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"javascript: URLs are not permitted in navigate. Use /evaluate instead.\"}", origin: origin)
                    return
                }
                let allowLocal = (json["allowLocalFiles"] as? Bool) ?? false
                if scheme == "file" && !allowLocal {
                    sendResponse(connection: connection, status: "403 Forbidden", body: "{\"error\":\"file:// URLs are disabled by default. Pass allowLocalFiles: true to navigate local files.\"}", origin: origin)
                    return
                }
                activeTab.load(url: url)
                // Brief pause to detect immediate provisional failure (e.g. invalid host / DNS resolution failure)
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let navError = activeTab.lastNavigationError {
                    sendJSON(connection: connection, object: ["success": false, "error": navError, "navigatedTo": url.absoluteString], origin: origin)
                } else {
                    sendJSON(connection: connection, object: ["success": true, "navigatedTo": url.absoluteString], origin: origin)
                }
            }

        case ("POST", "/navigate/back"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            if !activeTab.canGoBack {
                sendJSON(connection: connection, object: ["success": false, "action": "back", "message": "Cannot go back: navigation history is empty"], origin: origin)
            } else {
                store.goBack()
                sendJSON(connection: connection, object: ["success": true, "action": "back"], origin: origin)
            }

        case ("POST", "/navigate/forward"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            if !activeTab.canGoForward {
                sendJSON(connection: connection, object: ["success": false, "action": "forward", "message": "Cannot go forward: navigation history is empty"], origin: origin)
            } else {
                store.goForward()
                sendJSON(connection: connection, object: ["success": true, "action": "forward"], origin: origin)
            }

        case ("POST", "/navigate/reload"):
            store.reload()
            sendJSON(connection: connection, object: ["success": true, "action": "reload"], origin: origin)

        case ("POST", "/wait"):
            var targetTab: Tab? = store.activeTab
            var mode = "stability"
            var quietMs = 250
            var timeoutMs = 5000
            var durationMs = 1000
            var selector = ""
            var urlPattern = ""
            var idleMs = 500

            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let tid = json["tabId"] as? String { targetTab = resolveTab(id: tid) }
                if let m = json["mode"] as? String { mode = m.lowercased() }
                if let q = json["quietMs"] as? Int { quietMs = q }
                if let t = json["timeoutMs"] as? Int { timeoutMs = t }
                if let d = json["durationMs"] as? Int { durationMs = d }
                if let s = json["selector"] as? String { selector = s }
                if let u = json["urlPattern"] as? String { urlPattern = u }
                if let u = json["url"] as? String, urlPattern.isEmpty { urlPattern = u }
                if let i = json["idleMs"] as? Int { idleMs = i }
            }

            guard let activeTab = targetTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }

            // Auto-infer selector mode if selector string is present
            if !selector.isEmpty && (mode == "stability" || mode.isEmpty) {
                mode = "selector"
            }

            switch mode {
            case "stability", "stable", "domstable", "idle", "quiescence":
                do {
                    let result = try await activeTab.waitForStability(quietMs: quietMs, timeoutMs: timeoutMs)
                    sendJSON(connection: connection, object: result, origin: origin)
                } catch {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
                }

            case "selector":
                guard !selector.isEmpty else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing selector string\"}", origin: origin)
                    return
                }
                await activeTab.ensureNomadScriptInjected()
                let script = """
                return await new Promise(function(resolve) {
                    var sel = selector;
                    function checkNode() {
                        if (window.__nomad && window.__nomad.findInTree) {
                            var f = window.__nomad.findInTree(document, sel);
                            if (f) return f;
                        }
                        try {
                            return document.querySelector(sel);
                        } catch(e) {
                            return null;
                        }
                    }
                    if (checkNode()) {
                        resolve({ success: true, message: 'Element already present' });
                        return;
                    }
                    var timer = null;
                    var pollTimer = null;
                    var obs = null;
                    function cleanup() {
                        if (timer) clearTimeout(timer);
                        if (pollTimer) clearInterval(pollTimer);
                        if (obs) obs.disconnect();
                    }
                    timer = setTimeout(function() {
                        cleanup();
                        resolve({ success: false, message: 'Timeout waiting for ' + sel });
                    }, timeoutMs);
                    obs = new MutationObserver(function() {
                        if (checkNode()) {
                            cleanup();
                            resolve({ success: true, message: 'Element appeared' });
                        }
                    });
                    try {
                        obs.observe(document.documentElement || document.body, { childList: true, subtree: true, attributes: true });
                    } catch(e) {}
                    pollTimer = setInterval(function() {
                        if (checkNode()) {
                            cleanup();
                            resolve({ success: true, message: 'Element appeared' });
                        }
                    }, 50);
                });
                """
                do {
                    let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
                        activeTab.webView.callAsyncJavaScript(script, arguments: ["selector": selector, "timeoutMs": timeoutMs], in: nil, in: .page) { res in
                            switch res {
                            case .success(let val):
                                continuation.resume(returning: (val as? [String: Any]) ?? ["success": true, "selector": selector])
                            case .failure(let err):
                                continuation.resume(throwing: err)
                            }
                        }
                    }
                    sendJSON(connection: connection, object: result, origin: origin)
                } catch {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
                }

            case "networkidle", "network_idle":
                let startTime = Date()
                var lastActivity = Date()
                var prevCount = activeTab.networkEntries.count
                while Date().timeIntervalSince(startTime) < (Double(timeoutMs) / 1000.0) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let currentCount = activeTab.networkEntries.count
                    if currentCount != prevCount {
                        prevCount = currentCount
                        lastActivity = Date()
                    } else if Date().timeIntervalSince(lastActivity) >= (Double(idleMs) / 1000.0) && !activeTab.isLoading {
                        sendJSON(connection: connection, object: ["success": true, "message": "Network idle for \(idleMs)ms", "requests": currentCount], origin: origin)
                        return
                    }
                }
                sendJSON(connection: connection, object: ["success": false, "reason": "timeout", "message": "Exceeded max wait of \(timeoutMs)ms waiting for network idle"], origin: origin)

            case "navigation", "url":
                let expectedPattern = !urlPattern.isEmpty ? urlPattern : selector
                let startTime = Date()
                while Date().timeIntervalSince(startTime) < (Double(timeoutMs) / 1000.0) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let curUrl = activeTab.url?.absoluteString ?? ""
                    if !expectedPattern.isEmpty {
                        if curUrl.contains(expectedPattern) && !activeTab.isLoading {
                            sendJSON(connection: connection, object: ["success": true, "message": "Navigated to \(curUrl)", "url": curUrl], origin: origin)
                            return
                        }
                    } else if !activeTab.isLoading {
                        sendJSON(connection: connection, object: ["success": true, "message": "Navigation finished", "url": curUrl], origin: origin)
                        return
                    }
                }
                sendJSON(connection: connection, object: ["success": false, "reason": "timeout", "message": "Exceeded max wait of \(timeoutMs)ms waiting for navigation"], origin: origin)

            case "timeout", "sleep", "delay":
                try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
                sendJSON(connection: connection, object: ["success": true, "waitedMs": durationMs], origin: origin)

            default:
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Unknown wait mode: \(mode)\"}", origin: origin)
            }

        case ("GET", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let allCookies = await cookieStore.allCookies()
            let host = activeTab.url?.host ?? ""
            let allDomains = queryString.contains("allDomains=true")
            let matched = allCookies.filter { cookie in
                if allDomains { return true }
                return host.isEmpty || cookie.domain.contains(host) || host.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
            }.map { cookie -> [String: Any] in
                var dict: [String: Any] = [
                    "name": cookie.name,
                    "value": cookie.value,
                    "domain": cookie.domain,
                    "path": cookie.path,
                    "isSecure": cookie.isSecure,
                    "isHTTPOnly": cookie.isHTTPOnly
                ]
                if let exp = cookie.expiresDate {
                    dict["expires"] = exp.timeIntervalSince1970
                }
                return dict
            }
            sendJSON(connection: connection, object: ["cookies": matched, "domain": host, "allDomains": allDomains], origin: origin)

        case ("POST", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing cookie JSON body\"}", origin: origin)
                return
            }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let host = activeTab.url?.host ?? "localhost"

            var cookiesToSet: [[String: Any]] = []
            if let list = json["cookies"] as? [[String: Any]] {
                cookiesToSet = list
            } else if json["name"] != nil && json["value"] != nil {
                cookiesToSet = [json]
            }

            var setCount = 0
            for c in cookiesToSet {
                guard let name = c["name"] as? String, let value = c["value"] as? String else { continue }
                let domain = c["domain"] as? String ?? host
                let path = c["path"] as? String ?? "/"
                var props: [HTTPCookiePropertyKey: Any] = [
                    .name: name,
                    .value: value,
                    .domain: domain,
                    .path: path
                ]
                if let sec = (c["isSecure"] as? Bool) ?? (c["secure"] as? Bool), sec {
                    props[.secure] = "TRUE"
                }
                if let httpOnly = (c["isHTTPOnly"] as? Bool) ?? (c["httpOnly"] as? Bool) ?? (c["isHttpOnly"] as? Bool), httpOnly {
                    props[HTTPCookiePropertyKey(rawValue: "HttpOnly")] = "TRUE"
                }
                if let exp = (c["expires"] as? Double) ?? (c["expiry"] as? Double) {
                    props[.expires] = Date(timeIntervalSince1970: exp)
                }
                if let cookie = HTTPCookie(properties: props) {
                    await cookieStore.setCookie(cookie)
                    setCount += 1
                }
            }
            sendJSON(connection: connection, object: ["success": true, "setCount": setCount], origin: origin)

        case ("DELETE", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let allCookies = await cookieStore.allCookies()
            let host = activeTab.url?.host ?? ""
            let allDomains = queryString.contains("allDomains=true")
            var deletedCount = 0
            for cookie in allCookies {
                if allDomains || host.isEmpty || cookie.domain.contains(host) || host.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                    await cookieStore.deleteCookie(cookie)
                    deletedCount += 1
                }
            }
            sendJSON(connection: connection, object: ["success": true, "deletedCount": deletedCount], origin: origin)

        case ("GET", "/snapshot"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            var limit = 100
            var offset = 0
            var viewportOnly = false
            var includeText = true
            if let qItems = URLComponents(string: "?" + queryString)?.queryItems {
                for item in qItems {
                    if item.name == "limit", let v = item.value, let intV = Int(v) { limit = intV }
                    if item.name == "offset", let v = item.value, let intV = Int(v) { offset = intV }
                    if item.name == "viewportOnly", let v = item.value { viewportOnly = (v == "true" || v == "1") }
                    if item.name == "includeText", let v = item.value { includeText = (v != "false" && v != "0") }
                }
            }
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let l = json["limit"] as? Int { limit = l }
                if let o = json["offset"] as? Int { offset = o }
                if let v = json["viewportOnly"] as? Bool { viewportOnly = v }
                if let it = json["includeText"] as? Bool { includeText = it }
            }
            do {
                let snapshot = try await activeTab.getSemanticTree(limit: limit, offset: offset, viewportOnly: viewportOnly, includeText: includeText)
                let data = try JSONEncoder().encode(snapshot)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: data, origin: origin)
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
            }

        case ("POST", "/dialog"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let policy = json["policy"] as? String {
                    activeTab.dialogPolicy = policy
                }
                if let response = json["response"] as? String {
                    activeTab.dialogPromptResponse = response
                }
            }
            sendJSON(connection: connection, object: [
                "success": true,
                "policy": activeTab.dialogPolicy,
                "promptResponse": activeTab.dialogPromptResponse,
                "lastDialog": (activeTab.lastDialog as Any?) ?? NSNull()
            ], origin: origin)

        case ("GET", "/screenshot"), ("POST", "/screenshot"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            var isLabeled = queryString.contains("labeled=true")
            var elementId: String? = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "elementId" || $0.name == "ref" })?.value
            var clipRect: CGRect? = nil
            if let clipStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "clip" })?.value {
                let parts = clipStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                if parts.count == 4 {
                    clipRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                }
            }
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let labeledBool = json["labeled"] as? Bool { isLabeled = labeledBool }
                if let elId = json["elementId"] as? String { elementId = elId }
                if let clipDict = json["clip"] as? [String: Any],
                   let x = (clipDict["x"] as? NSNumber)?.doubleValue,
                   let y = (clipDict["y"] as? NSNumber)?.doubleValue,
                   let w = (clipDict["width"] as? NSNumber)?.doubleValue,
                   let h = (clipDict["height"] as? NSNumber)?.doubleValue {
                    clipRect = CGRect(x: x, y: y, width: w, height: h)
                }
            }
            do {
                let image = try await activeTab.captureScreenshot(labeled: isLabeled, elementId: elementId, clip: clipRect)
                if let png = image.pngData {
                    sendRaw(connection: connection, contentType: "image/png", data: png, origin: origin)
                } else {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"Failed to encode PNG data\"}", origin: origin)
                }
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(error.localizedDescription)\",\"success\":false}", origin: origin)
            }

        case ("POST", "/action"):
            var targetTab: Tab? = store.activeTab
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
               let tid = json["tabId"] as? String {
                targetTab = resolveTab(id: tid)
            }
            guard let activeTab = targetTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            guard let bodyData = bodyData else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing action body\"}", origin: origin)
                return
            }
            do {
                let action = try JSONDecoder().decode(NomadAction.self, from: bodyData)
                let result = try await activeTab.performAction(action)
                let resData = try JSONEncoder().encode(result)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: resData, origin: origin)
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
            }

        case ("POST", "/evaluate"):
            var targetTab: Tab? = store.activeTab
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
               let tid = json["tabId"] as? String {
                targetTab = resolveTab(id: tid)
            }
            guard let activeTab = targetTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let script = json["script"] as? String else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing script string in body\"}", origin: origin)
                return
            }
            let worldParam = (json["world"] as? String)?.lowercased() ?? "page"
            let contentWorld: WKContentWorld = (worldParam == "isolated") ? .defaultClient : .page

            let trimmed = script.trimmingCharacters(in: .whitespacesAndNewlines)
            let wrappedScript = """
            return await (async () => {
                try {
                    var __nomad_res;
                    try {
                        __nomad_res = await (async () => (\(trimmed)))();
                    } catch(__syntax_err) {
                        __nomad_res = await (async () => { \(trimmed) })();
                    }
                    return { __nomad_ok: true, value: __nomad_res };
                } catch(__nomad_eval_err) {
                    return {
                        __nomad_ok: false,
                        error: (__nomad_eval_err && __nomad_eval_err.message) ? __nomad_eval_err.message : String(__nomad_eval_err),
                        stack: (__nomad_eval_err && __nomad_eval_err.stack) ? __nomad_eval_err.stack : null,
                        name: (__nomad_eval_err && __nomad_eval_err.name) ? __nomad_eval_err.name : 'Error'
                    };
                }
            })();
            """
            do {
                let evalResult: Any? = try await withCheckedThrowingContinuation { continuation in
                    activeTab.webView.callAsyncJavaScript(wrappedScript, arguments: [:], in: nil, in: contentWorld) { result in
                        switch result {
                        case .success(let val):
                            continuation.resume(returning: val)
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
                }

                if let dict = evalResult as? [String: Any], dict["__nomad_ok"] as? Bool == false {
                    let errMsg = dict["error"] as? String ?? "JavaScript evaluation failed"
                    let errStack = dict["stack"] as? String
                    let errName = dict["name"] as? String ?? "EVAL_ERROR"
                    var resp: [String: Any] = [
                        "success": false,
                        "error": errMsg,
                        "code": errName
                    ]
                    if let stack = errStack { resp["stack"] = stack }
                    sendJSON(connection: connection, object: resp, origin: origin)
                    return
                }

                var rawValue: Any? = evalResult
                if let dict = evalResult as? [String: Any], dict["__nomad_ok"] as? Bool == true {
                    rawValue = dict["value"]
                }

                var responseObj: [String: Any] = ["success": true]
                if let val = rawValue {
                    if let strVal = val as? String {
                        if strVal.count > 50_000 {
                            responseObj["result"] = String(strVal.prefix(50_000)) + "\n... [truncated by Nomad: result exceeded 50,000 chars]"
                        } else {
                            responseObj["result"] = strVal
                        }
                    } else if JSONSerialization.isValidJSONObject([val]) || val is NSNumber || val is [Any] || val is [String: Any] {
                        responseObj["result"] = val
                    } else {
                        let repr = "\(val)"
                        if repr.count > 50_000 {
                            responseObj["result"] = String(repr.prefix(50_000)) + "\n... [truncated by Nomad: result exceeded 50,000 chars]"
                        } else {
                            responseObj["result"] = repr
                        }
                    }
                } else {
                    responseObj["result"] = NSNull()
                }
                sendJSON(connection: connection, object: responseObj, origin: origin)
            } catch {
                let nsErr = error as NSError
                var errMsg = nsErr.localizedDescription
                if let jsMsg = nsErr.userInfo["WKJavaScriptExceptionMessage"] as? String, !jsMsg.isEmpty {
                    errMsg = jsMsg
                }
                let isCSP = nsErr.domain == "WKErrorDomain" && (errMsg.contains("Content Security Policy") || errMsg.contains("CSP") || errMsg.contains("Refused to evaluate"))
                let errCode = isCSP ? "EVAL_CSP" : "EVAL_ERROR"
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(errMsg)\",\"code\":\"\(errCode)\",\"success\":false}", origin: origin)
            }

        case ("GET", "/console"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found\"}", origin: origin)
                return
            }
            let clear = queryString.contains("clear=true")
            let levelFilter = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "level" })?.value?.lowercased()
            let filtered = activeTab.consoleEntries.filter { entry in
                if let lvl = levelFilter, !lvl.isEmpty && lvl != "all" {
                    return entry.level.rawValue.lowercased() == lvl
                }
                return true
            }
            let entries = filtered.map { entry in
                [
                    "id": entry.id.uuidString,
                    "level": entry.level.rawValue,
                    "message": entry.message,
                    "timestamp": entry.timestamp.timeIntervalSince1970 * 1000.0
                ] as [String: Any]
            }
            if clear {
                activeTab.consoleEntries.removeAll()
            }
            sendJSON(connection: connection, object: [
                "success": true,
                "tabId": activeTab.id.uuidString,
                "count": entries.count,
                "entries": entries
            ], origin: origin)

        case ("POST", "/console/clear"), ("DELETE", "/console"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            activeTab.consoleEntries.removeAll()
            sendJSON(connection: connection, object: ["success": true, "cleared": true], origin: origin)

        case ("GET", "/network"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found\"}", origin: origin)
                return
            }
            let clear = queryString.contains("clear=true")
            let filter = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "statusFilter" })?.value ?? "all"
            let filtered = activeTab.networkEntries.filter { entry in
                if filter == "errors" { return entry.isError }
                if filter == "success" { return !entry.isError }
                return true
            }
            let entries = filtered.map { entry in
                [
                    "id": entry.id.uuidString,
                    "method": entry.method,
                    "url": entry.url,
                    "status": entry.status,
                    "durationMs": entry.durationMs,
                    "type": entry.type,
                    "isError": entry.isError,
                    "error": (entry.error as Any?) ?? NSNull(),
                    "timestamp": entry.timestamp.timeIntervalSince1970 * 1000.0
                ] as [String: Any]
            }
            if clear {
                activeTab.networkEntries.removeAll()
            }
            sendJSON(connection: connection, object: [
                "success": true,
                "tabId": activeTab.id.uuidString,
                "count": entries.count,
                "entries": entries
            ], origin: origin)

        case ("POST", "/network/clear"), ("DELETE", "/network"):
            let tabIdStr = URLComponents(string: "?" + queryString)?.queryItems?.first(where: { $0.name == "tabId" })?.value
            guard let activeTab = resolveTab(id: tabIdStr) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            activeTab.networkEntries.removeAll()
            sendJSON(connection: connection, object: ["success": true, "cleared": true], origin: origin)

        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Endpoint not found: \(method) \(path)\"}", origin: origin)
        }
    }

    // MARK: - HTTP Network Response Serialization

    nonisolated private func sendJSON(connection: NWConnection, status: String = "200 OK", object: Any, origin: String? = nil) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            sendRaw(connection: connection, status: status, contentType: "application/json; charset=utf-8", data: data, origin: origin)
        } else {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"JSON encoding error\"}", origin: origin)
        }
    }

    nonisolated private func sendResponse(connection: NWConnection, status: String, body: String, origin: String? = nil) {
        let bodyData = Data(body.utf8)
        sendRaw(connection: connection, status: status, contentType: "application/json; charset=utf-8", data: bodyData, origin: origin)
    }

    nonisolated private func sendRaw(connection: NWConnection, status: String = "200 OK", contentType: String, data: Data, origin: String? = nil) {
        var corsHeaders = ""
        if let origin = origin, !origin.isEmpty {
            corsHeaders = """
            Access-Control-Allow-Origin: \(origin)\r
            Access-Control-Allow-Methods: GET, POST, DELETE, OPTIONS\r
            Access-Control-Allow-Headers: Authorization, Content-Type, X-Nomad-Token\r\n
            """
        }
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        \(corsHeaders)Connection: close\r
        \r\n
        """
        var responseData = Data(headers.utf8)
        responseData.append(data)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
