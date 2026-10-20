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
import CryptoKit

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

    /// Constant-time string comparison to prevent timing attacks on bearer token authentication.
    nonisolated private static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let digestA = SHA256.hash(data: Data(a.utf8))
        let digestB = SHA256.hash(data: Data(b.utf8))
        return digestA == digestB
    }

    /// Validates request Origin header to prevent DNS rebinding and cross-site exfiltration attacks.
    nonisolated private static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin = origin, !origin.isEmpty else {
            // Local CLI, curl, Node.js, Python, or MCP servers emit no Origin header
            return true
        }
        let lower = origin.lowercased()
        if lower.hasPrefix("http://127.0.0.1") || lower.hasPrefix("https://127.0.0.1") { return true }
        if lower.hasPrefix("http://localhost") || lower.hasPrefix("https://localhost") { return true }
        if lower.hasPrefix("http://[::1]") || lower.hasPrefix("https://[::1]") { return true }
        if lower.hasPrefix("chrome-extension://") { return true }
        return false
    }

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = NomadAgentServer.defaultPort
    @Published private(set) var requestCount: Int = 0

    /// Secure local authentication token loaded from ~/.nomad/agent-token or NOMAD_TOKEN environment variable.
    let token: String = NomadAgentServer.loadOrCreateAgentToken()

    weak var store: BrowserStore?

    private var listener: NWListener?
    nonisolated private let serverQueue = DispatchQueue(label: "nomad.agent.server", qos: .userInitiated)

    /// Process activity assertion to ensure macOS App Nap and timer coalescing are disabled during agent server operations
    private var activityToken: NSObjectProtocol? = {
        ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
            reason: "Nomad Agent Server Automation"
        )
    }()

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

        // Validate Origin header against DNS rebinding & cross-site exfiltration attacks
        if !Self.isAllowedOrigin(origin) {
            print("🛡️ [NomadAgentServer] Blocked cross-origin request from untrusted origin: \(origin ?? "unknown")")
            sendResponse(connection: connection, status: "403 Forbidden", body: "{\"error\":\"Forbidden: cross-origin requests from untrusted web origins are blocked by Nomad security policy.\"}", origin: nil)
            return
        }

        // Handle CORS Preflight (only reached if origin is valid)
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "204 No Content", body: "", origin: origin)
            return
        }

        // Parse query params once into a fast lookup table
        let queryParams: [String: String] = {
            guard !queryString.isEmpty,
                  let items = URLComponents(string: "?" + queryString)?.queryItems else { return [:] }
            return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { _, last in last })
        }()

        func queryItem(_ name: String) -> String? {
            queryParams[name]
        }

        func queryBool(_ name: String, default defaultValue: Bool = false) -> Bool {
            guard let val = queryParams[name] else { return defaultValue }
            return val == "true" || val == "1"
        }

        // Token Auth check (bypassed if NOMAD_DISABLE_AUTH=1 in environment)
        let authDisabled = ProcessInfo.processInfo.environment["NOMAD_DISABLE_AUTH"] == "1"
        var isAuthenticated = authDisabled
        if !isAuthenticated {
            let authHeader = headers["authorization"] ?? ""
            var providedToken: String? = nil
            if authHeader.lowercased().starts(with: "bearer ") {
                providedToken = String(authHeader.dropFirst(7)).trimmingCharacters(in: .whitespaces)
            } else if let customHeader = headers["x-nomad-token"] {
                providedToken = customHeader.trimmingCharacters(in: .whitespaces)
            }

            if let tok = providedToken, Self.constantTimeEquals(tok, self.token) {
                isAuthenticated = true
            }
        }

        // Unauthenticated access is strictly limited to minimal health check probe without sensitive page data
        let isPublicHealthCheck = (method == "GET" && (path == "/" || path == "/status"))
        if !isAuthenticated {
            if isPublicHealthCheck {
                let publicStatusObj: [String: Any] = [
                    "nomad": "active",
                    "version": "1.0",
                    "port": self.port,
                    "authRequired": true
                ]
                sendJSON(connection: connection, object: publicStatusObj, origin: origin)
                return
            } else {
                sendResponse(connection: connection, status: "401 Unauthorized", body: "{\"error\":\"Unauthorized: valid Bearer token required in Authorization header or ~/.nomad/agent-token\"}", origin: origin)
                return
            }
        }

        func resolveTab(id: String?) -> Tab? {
            if let id = id, !id.isEmpty {
                guard let uuid = UUID(uuidString: id) else { return nil }
                return store.tabs.first(where: { $0.id == uuid })
            }
            return store.activeTab
        }

        func requireTab(id: String? = nil, errorMessage: String? = nil) -> Tab? {
            guard let tab = resolveTab(id: id) else {
                let msg: String
                if let errorMessage = errorMessage {
                    msg = errorMessage
                } else if let id = id, !id.isEmpty {
                    msg = "Tab not found with id '\(id)'"
                } else {
                    msg = "No active tab"
                }
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"\(msg)\"}", origin: origin)
                return nil
            }
            return tab
        }

        func handleNavAction(_ action: String, tab: Tab) {
            switch action {
            case "back":
                if !tab.canGoBack {
                    sendJSON(connection: connection, object: ["success": false, "action": "back", "message": "Cannot go back: navigation history is empty"], origin: origin)
                } else {
                    store.goBack()
                    sendJSON(connection: connection, object: ["success": true, "action": "back"], origin: origin)
                }
            case "forward":
                if !tab.canGoForward {
                    sendJSON(connection: connection, object: ["success": false, "action": "forward", "message": "Cannot go forward: navigation history is empty"], origin: origin)
                } else {
                    store.goForward()
                    sendJSON(connection: connection, object: ["success": true, "action": "forward"], origin: origin)
                }
            case "reload":
                store.reload()
                sendJSON(connection: connection, object: ["success": true, "action": "reload"], origin: origin)
            default:
                break
            }
        }

        func executeClearCookies(tab: Tab, targetDomain: String?, allDomains: Bool) async {
            let cookieStore = tab.webView.configuration.websiteDataStore.httpCookieStore
            let host = (targetDomain?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? tab.url?.host ?? ""
            var deletedCount = 0

            if allDomains {
                let all = await cookieStore.allCookies()
                deletedCount = all.count
                for c in all {
                    await cookieStore.deleteCookie(c)
                }
                await tab.webView.configuration.websiteDataStore.removeData(ofTypes: [WKWebsiteDataTypeCookies], modifiedSince: .distantPast)
                sendJSON(connection: connection, object: ["success": true, "deletedCount": deletedCount, "allDomains": true], origin: origin)
                return
            }

            let allCookies = await cookieStore.allCookies()
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            for cookie in allCookies {
                let cleanDomain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let matches = cleanHost.isEmpty || cleanDomain == cleanHost || cleanHost.hasSuffix("." + cleanDomain) || cleanDomain.hasSuffix("." + cleanHost)
                if matches {
                    await cookieStore.deleteCookie(cookie)
                    deletedCount += 1
                }
            }
            sendJSON(connection: connection, object: ["success": true, "deletedCount": deletedCount, "domain": host], origin: origin)
        }

        switch (method, path) {
        case ("GET", "/"), ("GET", "/status"):
            let capabilities: [String: Any] = [
                "waitModes": ["stability", "selector", "timeout", "networkidle", "navigation", "url"],
                "actions": ["click", "hover", "type", "clear", "press", "selectOption", "scroll", "drag", "highlight", "upload"],
                "upload": ["files", "paths"],
                "screenshot": ["full", "labeled", "clip", "elementId"],
                "evaluateWorlds": ["page", "isolated"],
                "snapshotModes": ["text", "json"],
                "cookies": ["get", "set", "clear"],
                "console": ["log", "warn", "error"],
                "network": ["fetch", "xhr", "status", "timing"]
            ]
            let liveTitle = (store.activeTab?.webView.title?.isEmpty == false ? store.activeTab?.webView.title : store.activeTab?.title) ?? ""
            let liveURL = (store.activeTab?.webView.url?.absoluteString ?? store.activeTab?.url?.absoluteString) ?? ""
            let statusObj: [String: Any] = [
                "nomad": "active",
                "version": "1.0",
                "port": self.port,
                "tabsCount": store.tabs.count,
                "tabCount": store.tabs.count,
                "activeTabId": store.activeTabId?.uuidString ?? "",
                "activeURL": liveURL,
                "activeUrl": liveURL,
                "activeTitle": liveTitle,
                "lastDialog": (store.activeTab?.lastDialog as Any?) ?? NSNull(),
                "capabilities": capabilities
            ]
            sendJSON(connection: connection, object: statusObj, origin: origin)

        case ("GET", "/tabs"):
            let tabsList: [[String: Any]] = store.tabs.map { tab -> [String: Any] in
                let title = (tab.webView.title?.isEmpty == false ? tab.webView.title : tab.title) ?? ""
                let urlStr = (tab.webView.url?.absoluteString ?? tab.url?.absoluteString) ?? ""
                return [
                    "id": tab.id.uuidString,
                    "title": title,
                    "url": urlStr,
                    "isIncognito": tab.isIncognito,
                    "isActive": tab.id == store.activeTabId,
                    "active": tab.id == store.activeTabId,
                    "isLoading": tab.isLoading
                ]
            }
            sendJSON(connection: connection, object: ["tabs": tabsList, "tabsCount": store.tabs.count], origin: origin)

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
            let newTitle = (newTab.webView.title?.isEmpty == false ? newTab.webView.title : newTab.title) ?? ""
            let newURL = (newTab.webView.url?.absoluteString ?? newTab.url?.absoluteString) ?? ""
            sendJSON(connection: connection, object: [
                "success": true,
                "tabId": newTab.id.uuidString,
                "title": newTitle,
                "url": newURL,
                "tabsCount": store.tabs.count
            ], origin: origin)

        case ("POST", "/tabs/switch"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\",\"code\":\"INVALID_TAB_ID\",\"success\":false}", origin: origin)
                return
            }
            guard store.tabs.contains(where: { $0.id == id }) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found: \(id.uuidString)\",\"code\":\"TAB_NOT_FOUND\",\"success\":false}", origin: origin)
                return
            }
            store.selectTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "activeTabId": id.uuidString, "tabsCount": store.tabs.count], origin: origin)

        case ("POST", "/tabs/close"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\",\"code\":\"INVALID_TAB_ID\",\"success\":false}", origin: origin)
                return
            }
            guard store.tabs.contains(where: { $0.id == id }) else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Tab not found: \(id.uuidString)\",\"code\":\"TAB_NOT_FOUND\",\"success\":false}", origin: origin)
                return
            }
            store.closeTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "closedTabId": id.uuidString, "tabsCount": store.tabs.count], origin: origin)

        case ("POST", "/navigate"):
            guard let bodyData = bodyData, !bodyData.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing body in /navigate\"}", origin: origin)
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in request body\"}", origin: origin)
                return
            }
            let tid = (json["tabId"] as? String) ?? queryItem("tabId")
            guard let activeTab = requireTab(id: tid) else { return }
            let action = (json["action"] as? String)?.lowercased()
            switch action {
            case "back", "forward", "reload":
                handleNavAction(action!, tab: activeTab)
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
                if scheme == "file" {
                    if !allowLocal {
                        sendResponse(connection: connection, status: "403 Forbidden", body: "{\"error\":\"file:// URLs are disabled by default. Pass allowLocalFiles: true to navigate local files.\"}", origin: origin)
                        return
                    }
                    let filePath = url.path
                    if !FileManager.default.fileExists(atPath: filePath) {
                        sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"File not found at path '\(filePath)'\",\"success\":false}", origin: origin)
                        return
                    }
                    let pathLower = filePath.lowercased()
                    if pathLower.contains("/.ssh") || pathLower.contains("/.nomad") || pathLower.contains("/library/keychains") || pathLower.contains("/etc/master.passwd") || pathLower.contains("/etc/sudoers") {
                        sendResponse(connection: connection, status: "403 Forbidden", body: "{\"error\":\"Access to sensitive directory or credential file is blocked by Nomad security policy.\"}", origin: origin)
                        return
                    }
                }
                let mySeq = activeTab.navigationSeq + 1
                activeTab.load(url: url)
                // Poll briefly (up to 350ms) to ensure provisional navigation starts or early DNS/host error is reported
                var navError: String? = nil
                var superseded = false
                let navStart = Date()
                while Date().timeIntervalSince(navStart) < 0.35 {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if activeTab.navigationSeq != mySeq {
                        superseded = true
                        break
                    }
                    if let err = activeTab.lastNavigationError {
                        navError = err
                        break
                    }
                }
                if superseded {
                    sendJSON(connection: connection, object: ["success": false, "cancelled": true, "reason": "superseded", "navigatedTo": url.absoluteString], origin: origin)
                } else if let navError = navError {
                    sendJSON(connection: connection, object: ["success": false, "error": navError, "navigatedTo": url.absoluteString], origin: origin)
                } else {
                    sendJSON(connection: connection, object: ["success": true, "navigatedTo": url.absoluteString], origin: origin)
                }
            }

        case ("POST", "/navigate/back"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            handleNavAction("back", tab: activeTab)

        case ("POST", "/navigate/forward"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            handleNavAction("forward", tab: activeTab)

        case ("POST", "/navigate/reload"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            handleNavAction("reload", tab: activeTab)

        case ("POST", "/wait"):
            var mode = "stability"
            var quietMs = 250
            var timeoutMs = 5000
            var durationMs = 1000
            var selector = ""
            var urlPattern = ""
            var idleMs = 500
            var tid: String? = nil

            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                tid = json["tabId"] as? String
                if let m = json["mode"] as? String { mode = m.lowercased() }
                if let q = json["quietMs"] as? Int { quietMs = q }
                if let t = json["timeoutMs"] as? Int { timeoutMs = t }
                if let d = json["durationMs"] as? Int { durationMs = d }
                if let s = json["selector"] as? String { selector = s }
                if let u = json["urlPattern"] as? String { urlPattern = u }
                if let u = json["url"] as? String, urlPattern.isEmpty { urlPattern = u }
                if let i = json["idleMs"] as? Int { idleMs = i }
            }

            guard let activeTab = requireTab(id: tid) else { return }

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
                let startTime = Date()
                let maxDuration = Double(timeoutMs) / 1000.0

                let escapedSelector: String
                if let data = try? JSONEncoder().encode(selector), let str = String(data: data, encoding: .utf8) {
                    escapedSelector = str
                } else {
                    escapedSelector = "\"\(selector)\""
                }

                let checkScript = """
                (() => {
                    var sel = \(escapedSelector);
                    if (window.__nomad && window.__nomad.findInTree) {
                        try {
                            if (window.__nomad.findInTree(document, sel)) return true;
                        } catch(e) {}
                    }
                    try {
                        return Boolean(document.querySelector(sel));
                    } catch(e) {
                        return false;
                    }
                })()
                """

                var found = false
                while Date().timeIntervalSince(startTime) < maxDuration {
                    if !activeTab.isLoading {
                        let res = (try? await activeTab.webView.evaluateJavaScript(checkScript)) as? Bool ?? false
                        if res {
                            found = true
                            break
                        }
                    }
                    try? await Task.sleep(nanoseconds: 50_000_000)
                }

                if found {
                    sendJSON(connection: connection, object: ["success": true, "selector": selector, "message": "Element appeared"], origin: origin)
                } else {
                    sendJSON(connection: connection, object: ["success": false, "reason": "timeout", "message": "Timeout waiting for selector '\(selector)'"], origin: origin)
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
                let regex = !expectedPattern.isEmpty ? try? NSRegularExpression(pattern: expectedPattern, options: .caseInsensitive) : nil
                let initialUrl = activeTab.url?.absoluteString ?? ""
                var didStartNavigating = activeTab.isLoading
                let startTime = Date()

                // If awaiting general navigation (no URL pattern) and the tab is already not loading:
                // Check if a navigation finished recently (< 3.0s ago) with no subsequent action dispatched.
                if expectedPattern.isEmpty && !activeTab.isLoading {
                    if let finish = activeTab.lastNavigationFinishTime,
                       Date().timeIntervalSince(finish) < 3.0,
                       (activeTab.lastActionTime == nil || activeTab.lastActionTime! <= finish) {
                        let curUrl = activeTab.url?.absoluteString ?? ""
                        sendJSON(connection: connection, object: ["success": true, "message": "Navigation finished", "url": curUrl], origin: origin)
                        return
                    }
                }

                while Date().timeIntervalSince(startTime) < (Double(timeoutMs) / 1000.0) {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    let curUrl = activeTab.url?.absoluteString ?? ""
                    let decodedUrl = curUrl.removingPercentEncoding ?? curUrl
                    if activeTab.isLoading {
                        didStartNavigating = true
                    }
                    if !expectedPattern.isEmpty {
                        let matchesSubstring = curUrl.contains(expectedPattern) || decodedUrl.contains(expectedPattern)
                        let matchesRegex: Bool
                        if let regex = regex {
                            let rangeCur = NSRange(curUrl.startIndex..., in: curUrl)
                            let rangeDecoded = NSRange(decodedUrl.startIndex..., in: decodedUrl)
                            matchesRegex = regex.firstMatch(in: curUrl, options: [], range: rangeCur) != nil ||
                                           regex.firstMatch(in: decodedUrl, options: [], range: rangeDecoded) != nil
                        } else {
                            matchesRegex = false
                        }
                        if (matchesSubstring || matchesRegex) && !activeTab.isLoading {
                            sendJSON(connection: connection, object: ["success": true, "message": "Navigated to \(curUrl)", "url": curUrl], origin: origin)
                            return
                        }
                    } else {
                        // When awaiting general navigation without a specific URL pattern,
                        // succeed if:
                        // 1. Tab was observed loading and now completed, OR
                        // 2. URL changed away from initialUrl and loading is false, OR
                        // 3. Navigation finished after wait call was received (lastNavigationFinishTime >= startTime)
                        let urlChanged = (!initialUrl.isEmpty && curUrl != initialUrl)
                        let finishedAfterStart = (activeTab.lastNavigationFinishTime != nil && activeTab.lastNavigationFinishTime! >= startTime)
                        if (didStartNavigating || urlChanged || finishedAfterStart) && !activeTab.isLoading {
                            sendJSON(connection: connection, object: ["success": true, "message": "Navigation finished", "url": curUrl], origin: origin)
                            return
                        }
                    }
                }
                let timeoutMsg = !expectedPattern.isEmpty ? "Exceeded max wait of \(timeoutMs)ms waiting for navigation to \(expectedPattern)" : "Exceeded max wait of \(timeoutMs)ms waiting for navigation (no navigation observed)"
                sendJSON(connection: connection, object: ["success": false, "reason": "timeout", "message": timeoutMsg], origin: origin)

            case "timeout", "sleep", "delay":
                try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
                sendJSON(connection: connection, object: ["success": true, "waitedMs": durationMs], origin: origin)

            default:
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Unknown wait mode: \(mode)\"}", origin: origin)
            }

        case ("GET", "/cookies"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let allCookies = await cookieStore.allCookies()
            let domainParam = queryItem("domain")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let host = (domainParam != nil && !domainParam!.isEmpty) ? domainParam! : (activeTab.url?.host ?? "")
            let allDomains = queryBool("allDomains")
            let cleanHost = host.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let matched = allCookies.filter { cookie in
                if allDomains { return true }
                let cleanDomain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return cleanHost.isEmpty || cleanDomain == cleanHost || cleanHost.hasSuffix("." + cleanDomain) || cleanDomain.hasSuffix("." + cleanHost)
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
            guard let bodyData = bodyData, !bodyData.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing cookie JSON body\"}", origin: origin)
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in cookie request body\"}", origin: origin)
                return
            }
            let tid = (json["tabId"] as? String) ?? queryItem("tabId")
            guard let activeTab = requireTab(id: tid) else { return }

            let action = (json["action"] as? String)?.lowercased()
            let allDomains = queryBool("allDomains") || (json["allDomains"] as? Bool == true)
            let domainParam = (json["domain"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? queryItem("domain")?.trimmingCharacters(in: .whitespacesAndNewlines)
            let targetDomain = (domainParam != nil && !domainParam!.isEmpty) ? domainParam! : (activeTab.url?.host ?? "")

            if action == "clear" || action == "delete" {
                await executeClearCookies(tab: activeTab, targetDomain: targetDomain, allDomains: allDomains)
                return
            }

            if action == "get" {
                let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
                let allCookies = await cookieStore.allCookies()
                let cleanHost = targetDomain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let matched = allCookies.filter { cookie in
                    if allDomains { return true }
                    let cleanDomain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    return cleanHost.isEmpty || cleanDomain == cleanHost || cleanHost.hasSuffix("." + cleanDomain) || cleanDomain.hasSuffix("." + cleanHost)
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
                sendJSON(connection: connection, object: ["cookies": matched, "domain": targetDomain, "allDomains": allDomains], origin: origin)
                return
            }

            // Otherwise, default to "set"
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let host = (targetDomain.isEmpty ? "localhost" : targetDomain)

            var cookiesToSet: [[String: Any]] = []
            if let list = json["cookies"] as? [[String: Any]] {
                cookiesToSet = list
            } else if json["name"] != nil && json["value"] != nil {
                cookiesToSet = [json]
            }

            if cookiesToSet.isEmpty {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"No cookie definition provided to set (expected 'name' and 'value' or 'cookies' array)\"}", origin: origin)
                return
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
            let json = (bodyData != nil && !bodyData!.isEmpty) ? (try? JSONSerialization.jsonObject(with: bodyData!)) as? [String: Any] : nil
            let tid = (json?["tabId"] as? String) ?? queryItem("tabId")
            guard let activeTab = requireTab(id: tid) else { return }
            var allDomains = queryBool("allDomains")
            var targetDomain = queryItem("domain")?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = json {
                if let bAll = json["allDomains"] as? Bool {
                    allDomains = allDomains || bAll
                }
                if let d = json["domain"] as? String, !d.isEmpty {
                    targetDomain = d.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
            await executeClearCookies(tab: activeTab, targetDomain: targetDomain, allDomains: allDomains)

        case ("GET", "/snapshot"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            var limit = queryItem("limit").flatMap(Int.init) ?? 100
            var offset = queryItem("offset").flatMap(Int.init) ?? 0
            var viewportOnly = queryBool("viewportOnly")
            var includeText = (queryItem("includeText") != "false" && queryItem("includeText") != "0")
            var mode = queryItem("mode")?.lowercased()
            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let l = json["limit"] as? Int { limit = l }
                if let o = json["offset"] as? Int { offset = o }
                if let v = json["viewportOnly"] as? Bool { viewportOnly = v }
                if let it = json["includeText"] as? Bool { includeText = it }
                if let m = json["mode"] as? String { mode = m.lowercased() }
            }
            do {
                let snapshot = try await activeTab.getSemanticTree(limit: limit, offset: offset, viewportOnly: viewportOnly, includeText: includeText)
                if mode == "json" || mode == "full" {
                    var fullSnapshot = snapshot
                    // Compute accurate full token estimate including the elements array
                    let rawData = try JSONEncoder().encode(snapshot)
                    let fullTokens = max(1, Int(ceil(Double(rawData.count) / 4.0)))
                    fullSnapshot.tokenEstimate = fullTokens
                    let data = try JSONEncoder().encode(fullSnapshot)
                    sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: data, origin: origin)
                } else {
                    // Default perception mode (mode == nil, "text", or "summary"): compact semantic markdown
                    let textTokens = max(1, Int(ceil(Double(snapshot.summary.utf8.count) / 4.0)))
                    var resp: [String: Any] = [
                        "success": true,
                        "title": snapshot.title,
                        "url": snapshot.url,
                        "summary": snapshot.summary,
                        "tokenEstimate": textTokens
                    ]
                    if let te = snapshot.totalElements { resp["totalElements"] = te }
                    sendJSON(connection: connection, object: resp, origin: origin)
                }
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
            }

        case ("POST", "/dialog"):
            guard let activeTab = requireTab() else { return }
            if let bodyData = bodyData, !bodyData.isEmpty {
                guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in dialog body\"}", origin: origin)
                    return
                }
                if let policy = json["policy"] as? String {
                    activeTab.dialogPolicy = policy
                }
                if let response = (json["response"] as? String) ?? (json["promptResponse"] as? String) {
                    activeTab.dialogPromptResponse = response
                }
            }
            sendJSON(connection: connection, object: [
                "success": true,
                "policy": activeTab.dialogPolicy,
                "response": activeTab.dialogPromptResponse,
                "promptResponse": activeTab.dialogPromptResponse,
                "lastDialog": (activeTab.lastDialog as Any?) ?? NSNull()
            ], origin: origin)

        case ("GET", "/screenshot"), ("POST", "/screenshot"):
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            var isLabeled = queryBool("labeled")
            var elementId: String? = queryItem("elementId") ?? queryItem("ref")
            var clipRect: CGRect? = nil
            if let clipStr = queryItem("clip") {
                let parts = clipStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                guard parts.count == 4, parts[2] > 0, parts[3] > 0, !parts[0].isNaN, !parts[1].isNaN, !parts[2].isNaN, !parts[3].isNaN else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid clip parameter. Expected 4 positive numbers x,y,width,height\",\"success\":false}", origin: origin)
                    return
                }
                clipRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
            }
            if let bodyData = bodyData, !bodyData.isEmpty {
                guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in screenshot body\",\"success\":false}", origin: origin)
                    return
                }
                if let labeledBool = json["labeled"] as? Bool { isLabeled = labeledBool }
                if let elId = json["elementId"] as? String { elementId = elId }
                if let clipRaw = json["clip"] {
                    if let clipDict = clipRaw as? [String: Any],
                       let x = (clipDict["x"] as? NSNumber)?.doubleValue,
                       let y = (clipDict["y"] as? NSNumber)?.doubleValue,
                       let w = (clipDict["width"] as? NSNumber)?.doubleValue,
                       let h = (clipDict["height"] as? NSNumber)?.doubleValue,
                       w > 0, h > 0, !x.isNaN, !y.isNaN, !w.isNaN, !h.isNaN {
                        clipRect = CGRect(x: x, y: y, width: w, height: h)
                    } else if let clipStr = clipRaw as? String {
                        let parts = clipStr.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                        guard parts.count == 4, parts[2] > 0, parts[3] > 0, !parts[0].isNaN, !parts[1].isNaN, !parts[2].isNaN, !parts[3].isNaN else {
                            sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid clip string in body. Expected x,y,width,height with positive dimensions\",\"success\":false}", origin: origin)
                            return
                        }
                        clipRect = CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                    } else {
                        sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Invalid clip object. Expected {x, y, width > 0, height > 0}\",\"success\":false}", origin: origin)
                        return
                    }
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
            guard let bodyData = bodyData, !bodyData.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing action body\",\"code\":\"MISSING_BODY\",\"success\":false}", origin: origin)
                return
            }
            let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any]
            if json == nil {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in action body\",\"code\":\"MALFORMED_JSON\",\"success\":false}", origin: origin)
                return
            }
            let tid = json?["tabId"] as? String
            guard let activeTab = requireTab(id: tid) else { return }
            do {
                let action = try JSONDecoder().decode(NomadAction.self, from: bodyData)
                let result = try await activeTab.performAction(action)
                let resData = try JSONEncoder().encode(result)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: resData, origin: origin)
            } catch let decodingError as DecodingError {
                let msg: String
                switch decodingError {
                case .dataCorrupted(let ctx):
                    msg = ctx.debugDescription
                case .keyNotFound(let key, _):
                    msg = "Missing required key '\(key.stringValue)'"
                case .typeMismatch(_, let ctx):
                    msg = ctx.debugDescription
                case .valueNotFound(_, let ctx):
                    msg = ctx.debugDescription
                @unknown default:
                    msg = decodingError.localizedDescription
                }
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(msg)\",\"code\":\"INVALID_ACTION_PAYLOAD\",\"success\":false}", origin: origin)
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(error.localizedDescription)\",\"code\":\"ACTION_ERROR\",\"success\":false}", origin: origin)
            }

        case ("POST", "/upload"):
            guard let bodyData = bodyData, !bodyData.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing upload body\",\"code\":\"MISSING_BODY\",\"success\":false}", origin: origin)
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in upload body\",\"code\":\"MALFORMED_JSON\",\"success\":false}", origin: origin)
                return
            }
            let targetId = (json["elementId"] as? String) ?? (json["target"] as? String) ?? (json["selector"] as? String)
            guard let targetId = targetId, !targetId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing required 'elementId' or 'target' in upload body\",\"code\":\"MISSING_TARGET\",\"success\":false}", origin: origin)
                return
            }
            var paths: [String] = []
            if let arr = json["paths"] as? [String] {
                paths = arr
            } else if let arr = json["files"] as? [String] {
                paths = arr
            } else if let single = json["path"] as? String {
                paths = [single]
            } else if let single = json["file"] as? String {
                paths = [single]
            }
            guard !paths.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing required 'paths' or 'files' array in upload body\",\"code\":\"MISSING_PATHS\",\"success\":false}", origin: origin)
                return
            }
            let tid = json["tabId"] as? String
            guard let activeTab = requireTab(id: tid) else { return }
            do {
                let action = NomadAction(action: "upload", target: targetId, paths: paths)
                let result = try await activeTab.performAction(action)
                let resData = try JSONEncoder().encode(result)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: resData, origin: origin)
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(error.localizedDescription)\",\"code\":\"UPLOAD_ERROR\",\"success\":false}", origin: origin)
            }

        case ("POST", "/evaluate"):
            guard let bodyData = bodyData, !bodyData.isEmpty else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing body in /evaluate\"}", origin: origin)
                return
            }
            guard let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Malformed JSON in evaluate body\"}", origin: origin)
                return
            }
            guard let script = (json["script"] as? String) ?? (json["expression"] as? String) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing script or expression string in body\"}", origin: origin)
                return
            }
            let tid = json["tabId"] as? String
            guard let activeTab = requireTab(id: tid) else { return }
            if activeTab.webView.isLoading {
                let start = Date()
                while activeTab.webView.isLoading && Date().timeIntervalSince(start) < 0.4 {
                    try? await Task.sleep(nanoseconds: 30_000_000)
                }
                if activeTab.webView.isLoading {
                    sendJSON(connection: connection, object: [
                        "success": false,
                        "error": "Cannot evaluate script: active page is currently navigating. Wait for navigation to complete before evaluating scripts.",
                        "code": "NAVIGATION_BUSY"
                    ], origin: origin)
                    return
                }
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
                let isSyntax = errMsg.contains("SyntaxError") || errMsg.contains("Unexpected token")
                let errCode = isCSP ? "EVAL_CSP" : (isSyntax ? "SYNTAX_ERROR" : "EVAL_ERROR")
                sendJSON(connection: connection, object: [
                    "success": false,
                    "error": errMsg,
                    "code": errCode
                ], origin: origin)
            }

        case ("GET", "/console"):
            guard let activeTab = requireTab(id: queryItem("tabId"), errorMessage: "Tab not found") else { return }
            let clear = queryBool("clear")
            let levelFilter = queryItem("level")?.lowercased()
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
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
            activeTab.consoleEntries.removeAll()
            sendJSON(connection: connection, object: ["success": true, "cleared": true], origin: origin)

        case ("GET", "/network"):
            guard let activeTab = requireTab(id: queryItem("tabId"), errorMessage: "Tab not found") else { return }
            let clear = queryBool("clear")
            let filter = queryItem("statusFilter") ?? "all"
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
            guard let activeTab = requireTab(id: queryItem("tabId")) else { return }
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
        if let origin = origin, !origin.isEmpty, Self.isAllowedOrigin(origin) {
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
