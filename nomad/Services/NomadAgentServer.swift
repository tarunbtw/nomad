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

    @Published private(set) var isRunning: Bool = false
    @Published private(set) var port: UInt16 = 9222
    @Published private(set) var requestCount: Int = 0

    weak var store: BrowserStore?

    private var listener: NWListener?
    nonisolated private let serverQueue = DispatchQueue(label: "nomad.agent.server", qos: .userInitiated)

    private init() {}

    /// Starts the local agent server on 127.0.0.1:9222.
    @MainActor
    func start(port: UInt16 = 9222, store: BrowserStore? = nil) {
        if let store = store {
            self.store = store
        }
        guard !isRunning else { return }
        self.port = port

        do {
            let tcpOptions = NWProtocolTCP.Options()
            tcpOptions.enableKeepalive = false
            let params = NWParameters(tls: nil, tcp: tcpOptions)
            params.allowLocalEndpointReuse = true
            params.requiredInterfaceType = .loopback

            guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
                print("⚠️ [NomadAgentServer] Invalid port: \(port)")
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
                  let json = (try? JSONSerialization.jsonObject(with: bodyData)) as? [String: Any],
                  let urlStr = json["url"] as? String,
                  let url = URL(string: urlStr) else {
                sendResponse(connection: connection, status: "400 Bad Request", body: "{\"error\":\"Missing or invalid url in body\"}")
                return
            }
            activeTab.load(url: url)
            sendJSON(connection: connection, object: ["success": true, "navigatedTo": url.absoluteString])

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

        case ("GET", "/screenshot"):
            guard let activeTab = store.activeTab else {
                sendResponse(connection: connection, status: "404 Not Found", body: "{\"error\":\"No active tab\"}")
                return
            }
            let isLabeled = queryString.contains("labeled=true")
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
            do {
                let result = try await activeTab.webView.evaluateJavaScript(script)
                sendJSON(connection: connection, object: ["success": true, "result": "\(result ?? "")"])
            } catch {
                sendResponse(connection: connection, status: "500 Internal Server Error", body: "{\"error\":\"\(error.localizedDescription)\"}")
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
