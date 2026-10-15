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

        switch (method, path) {
        case ("GET", "/"), ("GET", "/status"):
            let statusObj: [String: Any] = [
                "nomad": "active",
                "version": "1.0",
                "port": self.port,
                "tabsCount": store.tabs.count,
                "activeTabId": store.activeTabId?.uuidString ?? "",
                "activeURL": store.activeTab?.url?.absoluteString ?? "",
                "activeTitle": store.activeTab?.title ?? "",
                "lastDialog": store.activeTab?.lastDialog ?? NSNull()
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
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            var mode = "stability"
            var quietMs = 250
            var timeoutMs = 5000
            var durationMs = 1000
            var selector = ""

            if let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] {
                if let m = json["mode"] as? String { mode = m.lowercased() }
                if let q = json["quietMs"] as? Int { quietMs = q }
                if let t = json["timeoutMs"] as? Int { timeoutMs = t }
                if let d = json["durationMs"] as? Int { durationMs = d }
                if let s = json["selector"] as? String { selector = s }
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
                let script = """
                return await new Promise(function(resolve) {
                    var sel = selector;
                    if (document.querySelector(sel)) {
                        resolve({ success: true, message: 'Element already present' });
                        return;
                    }
                    var timer = setTimeout(function() {
                        obs.disconnect();
                        resolve({ success: false, message: 'Timeout waiting for ' + sel });
                    }, timeoutMs);
                    var obs = new MutationObserver(function() {
                        if (document.querySelector(sel)) {
                            clearTimeout(timer);
                            obs.disconnect();
                            resolve({ success: true, message: 'Element appeared' });
                        }
                    });
                    obs.observe(document.documentElement || document.body, { childList: true, subtree: true, attributes: true });
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
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            do {
                let snapshot = try await activeTab.getSemanticTree()
                let data = try JSONEncoder().encode(snapshot)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: data, origin: origin)
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
            }

        case ("GET", "/screenshot"), ("POST", "/screenshot"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}", origin: origin)
                return
            }
            var isLabeled = queryString.contains("labeled=true")
            if !isLabeled, let bodyData = bodyData,
               let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
               let labeledBool = json["labeled"] as? Bool {
                isLabeled = labeledBool
            }
            do {
                let image = try await activeTab.captureScreenshot(labeled: isLabeled)
                if let png = image.pngData {
                    sendRaw(connection: connection, contentType: "image/png", data: png, origin: origin)
                } else {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"Failed to encode PNG data\"}", origin: origin)
                }
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}", origin: origin)
            }

        case ("POST", "/action"):
            guard let activeTab = store.activeTab else {
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
            guard let activeTab = store.activeTab else {
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
            let wrappedScript: String
            if trimmed.starts(with: "return ") || trimmed.starts(with: "return\n") {
                wrappedScript = trimmed
            } else {
                wrappedScript = """
                try {
                    return await (async () => (\(trimmed)))();
                } catch(e) {
                    return await (async () => { \(trimmed) })();
                }
                """
            }
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

                var responseObj: [String: Any] = ["success": true]
                if let val = evalResult {
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
                let isCSP = nsErr.domain == "WKErrorDomain" && (nsErr.localizedDescription.contains("Content Security Policy") || nsErr.localizedDescription.contains("CSP"))
                let errCode = isCSP ? "EVAL_CSP" : "EVAL_ERROR"
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\",\"code\":\"\(errCode)\",\"success\":false}", origin: origin)
            }

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
