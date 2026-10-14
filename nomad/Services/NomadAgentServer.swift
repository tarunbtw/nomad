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

    weak var store: BrowserStore?

    private var listener: NWListener?
    nonisolated private let serverQueue = DispatchQueue(label: "nomad.agent.server", qos: .userInitiated)

    private init() {}

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
                        print("🟢 [NomadAgentServer] Listening on http://127.0.0.1:\(self.port)")
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

        // Extract body if present
        var bodyData: Data? = nil
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            let bodySub = requestString[bodyRange.upperBound...]
            bodyData = bodySub.data(using: .utf8)
        }

        Task { @MainActor in
            self.requestCount += 1
            await self.routeRequest(method: method, path: path, queryString: queryString, bodyData: bodyData, connection: connection)
        }
    }

    @MainActor
    private func routeRequest(method: String, path: String, queryString: String, bodyData: Data?, connection: NWConnection) async {
        guard let store = self.store else {
            sendResponse(connection: connection, status: "503 Service Unavailable", body: "{\"error\":\"BrowserStore not connected\"}")
            return
        }

        // Handle CORS Preflight
        if method == "OPTIONS" {
            sendResponse(connection: connection, status: "204 No Content", body: "")
            return
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
                "activeTitle": store.activeTab?.title ?? ""
            ]
            sendJSON(connection: connection, object: statusObj)

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
            sendJSON(connection: connection, object: ["tabs": tabsList])

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
            ])

        case ("POST", "/tabs/switch"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\"}")
                return
            }
            store.selectTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "activeTabId": id.uuidString])

        case ("POST", "/tabs/close"):
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let idStr = json["id"] as? String,
                  let id = UUID(uuidString: idStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid tab id\"}")
                return
            }
            store.closeTab(id: id)
            sendJSON(connection: connection, object: ["success": true, "closedTabId": id.uuidString])

        case ("POST", "/navigate"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing body in /navigate\"}")
                return
            }
            let action = (json["action"] as? String)?.lowercased()
            switch action {
            case "back":
                store.goBack()
                sendJSON(connection: connection, object: ["success": true, "action": "back"])
            case "forward":
                store.goForward()
                sendJSON(connection: connection, object: ["success": true, "action": "forward"])
            case "reload":
                store.reload()
                sendJSON(connection: connection, object: ["success": true, "action": "reload"])
            default:
                guard let urlStr = json["url"] as? String, let url = URL(string: urlStr), url.scheme != nil else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid url in body\"}")
                    return
                }
                activeTab.load(url: url)
                // Brief pause to detect immediate provisional failure (e.g. invalid host / DNS resolution failure)
                try? await Task.sleep(nanoseconds: 120_000_000)
                if let navError = activeTab.lastNavigationError {
                    sendJSON(connection: connection, object: ["success": false, "error": navError, "navigatedTo": url.absoluteString])
                } else {
                    sendJSON(connection: connection, object: ["success": true, "navigatedTo": url.absoluteString])
                }
            }

        case ("POST", "/navigate/back"):
            store.goBack()
            sendJSON(connection: connection, object: ["success": true, "action": "back"])

        case ("POST", "/navigate/forward"):
            store.goForward()
            sendJSON(connection: connection, object: ["success": true, "action": "forward"])

        case ("POST", "/navigate/reload"):
            store.reload()
            sendJSON(connection: connection, object: ["success": true, "action": "reload"])

        case ("POST", "/wait"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
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
                    sendJSON(connection: connection, object: result)
                } catch {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}")
                }

            case "selector":
                guard !selector.isEmpty else {
                    sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing selector string\"}")
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
                    obs.observe(document.body || document.documentElement, { childList: true, subtree: true, attributes: true });
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
                    sendJSON(connection: connection, object: result)
                } catch {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}")
                }

            case "timeout", "sleep", "delay":
                try? await Task.sleep(nanoseconds: UInt64(durationMs) * 1_000_000)
                sendJSON(connection: connection, object: ["success": true, "waitedMs": durationMs])

            default:
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Unknown wait mode: \(mode)\"}")
            }

        case ("GET", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let allCookies = await cookieStore.allCookies()
            let host = activeTab.url?.host ?? ""
            let matched = allCookies.filter { cookie in
                host.isEmpty || cookie.domain.contains(host) || host.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
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
            sendJSON(connection: connection, object: ["cookies": matched, "domain": host])

        case ("POST", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any] else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing cookie JSON body\"}")
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
            sendJSON(connection: connection, object: ["success": true, "setCount": setCount])

        case ("DELETE", "/cookies"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            let cookieStore = activeTab.webView.configuration.websiteDataStore.httpCookieStore
            let allCookies = await cookieStore.allCookies()
            let host = activeTab.url?.host ?? ""
            var deletedCount = 0
            for cookie in allCookies {
                if host.isEmpty || cookie.domain.contains(host) || host.contains(cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))) {
                    await cookieStore.deleteCookie(cookie)
                    deletedCount += 1
                }
            }
            sendJSON(connection: connection, object: ["success": true, "deletedCount": deletedCount])

        case ("GET", "/snapshot"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            do {
                let snapshot = try await activeTab.getSemanticTree()
                let data = try JSONEncoder().encode(snapshot)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: data)
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}")
            }

        case ("GET", "/screenshot"), ("POST", "/screenshot"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
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
                    sendRaw(connection: connection, contentType: "image/png", data: png)
                } else {
                    sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"Failed to encode PNG data\"}")
                }
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}")
            }

        case ("POST", "/action"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            guard let bodyData = bodyData else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing action body\"}")
                return
            }
            do {
                let action = try JSONDecoder().decode(NomadAction.self, from: bodyData)
                let result = try await activeTab.performAction(action)
                let resData = try JSONEncoder().encode(result)
                sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: resData)
            } catch {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"\(error.localizedDescription)\"}")
            }

        case ("POST", "/evaluate"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            guard let bodyData = bodyData,
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let script = json["script"] as? String else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing script string in body\"}")
                return
            }
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
                    activeTab.webView.callAsyncJavaScript(wrappedScript, arguments: [:], in: nil, in: .defaultClient) { result in
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
                    if JSONSerialization.isValidJSONObject([val]) || val is String || val is NSNumber || val is [Any] || val is [String: Any] {
                        responseObj["result"] = val
                    } else {
                        responseObj["result"] = "\(val)"
                    }
                } else {
                    responseObj["result"] = NSNull()
                }
                sendJSON(connection: connection, object: responseObj)
            } catch {
                let nsErr = error as NSError
                let isCSP = nsErr.domain == "WKErrorDomain" && (nsErr.code == 4 || nsErr.localizedDescription.contains("Content Security Policy"))
                let errCode = isCSP ? "EVAL_CSP" : "EVAL_ERROR"
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\",\"code\":\"\(errCode)\",\"success\":false}")
            }

        default:
            sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"Endpoint not found: \(method) \(path)\"}")
        }
    }

    // MARK: - HTTP Network Response Serialization

    nonisolated private func sendJSON(connection: NWConnection, object: Any) {
        if let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted]) {
            sendRaw(connection: connection, contentType: "application/json; charset=utf-8", data: data)
        } else {
            sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"JSON encoding error\"}")
        }
    }

    nonisolated private func sendResponse(connection: NWConnection, status: String, body: String) {
        let bodyData = Data(body.utf8)
        sendRaw(connection: connection, status: status, contentType: "application/json; charset=utf-8", data: bodyData)
    }

    nonisolated private func sendRaw(connection: NWConnection, status: String = "200 OK", contentType: String, data: Data) {
        let headers = """
        HTTP/1.1 \(status)\r
        Content-Type: \(contentType)\r
        Content-Length: \(data.count)\r
        Access-Control-Allow-Origin: *\r
        Access-Control-Allow-Methods: GET, POST, OPTIONS\r
        Access-Control-Allow-Headers: Content-Type\r
        Connection: close\r
        \r\n
        """
        var responseData = Data(headers.utf8)
        responseData.append(data)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
