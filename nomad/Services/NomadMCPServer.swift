//
//  NomadMCPServer.swift
//  nomad
//
//  Created by tarun on 16/10/26.
//

import Foundation

/// Native, zero-dependency Model Context Protocol (MCP) server for Nomad.
/// Bridges AI agent runtimes (Claude Code, Cursor, Antigravity) to Nomad's running
/// engine via JSON-RPC 2.0 stdio, eliminating the need for Node.js or npm.
final class NomadMCPServer {

    private static var port: Int {
        if let envStr = ProcessInfo.processInfo.environment["NOMAD_AGENT_PORT"],
           let p = Int(envStr) {
            return p
        }
        return 9222
    }

    private static func loadToken() -> String? {
        if let envToken = ProcessInfo.processInfo.environment["NOMAD_TOKEN"], !envToken.isEmpty {
            return envToken.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tokenFile = home.appendingPathComponent(".nomad/agent-token")
        if let token = try? String(contentsOf: tokenFile, encoding: .utf8) {
            let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }

    /// Synchronous stdio message loop executed when Nomad is launched with `--mcp`.
    static func run() {
        let inputHandle = FileHandle.standardInput
        var buffer = Data()

        while true {
            let chunk = inputHandle.availableData
            if chunk.isEmpty {
                // EOF on stdin (parent agent closed connection)
                break
            }
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !line.isEmpty {
                    handleMessage(line)
                }
            }
        }
    }

    private static func handleMessage(_ rawLine: String) {
        guard let data = rawLine.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return
        }

        let id = json["id"]
        let method = json["method"] as? String ?? ""
        let params = json["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            let result: [String: Any] = [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": [:] as [String: Any]
                ],
                "serverInfo": [
                    "name": "nomad-browser",
                    "version": "1.0.0"
                ]
            ]
            sendResponse(id: id, result: result)

        case "notifications/initialized":
            // Notification: no response required
            break

        case "ping":
            sendResponse(id: id, result: [:] as [String: Any])

        case "tools/list":
            sendResponse(id: id, result: ["tools": toolsManifest])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let toolArgs = params["arguments"] as? [String: Any] ?? [:]
            executeTool(name: toolName, args: toolArgs, id: id)

        default:
            if id != nil {
                sendError(id: id, code: -32601, message: "Method not found: \(method)")
            }
        }
    }

    private static func executeTool(name: String, args: [String: Any], id: Any?) {
        switch name {
        case "nomad_status":
            callNomad(method: "GET", path: "/status") { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_tabs":
            callNomad(method: "GET", path: "/tabs") { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_new_tab":
            callNomad(method: "POST", path: "/tabs/new", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_switch_tab":
            callNomad(method: "POST", path: "/tabs/switch", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_close_tab":
            callNomad(method: "POST", path: "/tabs/close", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_navigate":
            let action = (args["action"] as? String)?.lowercased()
            if action == "back" {
                callNomad(method: "POST", path: "/navigate/back") { res, err in respondTool(id: id, res: res, error: err) }
            } else if action == "forward" {
                callNomad(method: "POST", path: "/navigate/forward") { res, err in respondTool(id: id, res: res, error: err) }
            } else if action == "reload" {
                callNomad(method: "POST", path: "/navigate/reload") { res, err in respondTool(id: id, res: res, error: err) }
            } else {
                callNomad(method: "POST", path: "/navigate", body: args) { res, err in respondTool(id: id, res: res, error: err) }
            }

        case "nomad_snapshot":
            var qs: [String] = []
            if let l = args["limit"] as? Int { qs.append("limit=\(l)") }
            if let o = args["offset"] as? Int { qs.append("offset=\(o)") }
            if let v = args["viewportOnly"] as? Bool, v { qs.append("viewportOnly=true") }
            if let it = args["includeText"] as? Bool { qs.append("includeText=\(it)") }
            if let m = args["mode"] as? String { qs.append("mode=\(m.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? m)") }
            if let r = args["role"] as? String { qs.append("role=\(r.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? r)") }
            if let txt = args["text"] as? String { qs.append("text=\(txt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? txt)") }
            if let t = args["tabId"] as? String { qs.append("tabId=\(t.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? t)") }
            let path = qs.isEmpty ? "/snapshot" : "/snapshot?" + qs.joined(separator: "&")
            callNomad(method: "GET", path: path) { res, err in
                if let err = err {
                    respondTool(id: id, res: nil, error: err)
                    return
                }
                guard let dict = res as? [String: Any] else {
                    respondTool(id: id, res: res, error: nil)
                    return
                }
                if (args["mode"] as? String) == "json" {
                    if let prettyData = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
                       let str = String(data: prettyData, encoding: .utf8) {
                        sendToolText(id: id, text: str)
                    } else {
                        respondTool(id: id, res: dict, error: nil)
                    }
                    return
                }
                let summary = dict["summary"] as? String ?? ""
                let tokens = dict["tokenEstimate"] as? Int ?? 0
                let urlStr = dict["url"] as? String ?? ""
                let title = dict["title"] as? String ?? ""
                let text = "=== Nomad Semantic Perception ===\nTokens: ~\(tokens)\nURL: \(urlStr)\nTitle: \(title)\n\n\(summary)"
                sendToolText(id: id, text: text)
            }

        case "nomad_action":
            callNomad(method: "POST", path: "/action", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_upload":
            callNomad(method: "POST", path: "/upload", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_wait":
            callNomad(method: "POST", path: "/wait", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_cookies":
            let action = (args["action"] as? String)?.lowercased() ?? "get"
            var qs: [String] = []
            if let ad = args["allDomains"] as? Bool, ad { qs.append("allDomains=true") }
            if let dom = args["domain"] as? String, !dom.isEmpty { qs.append("domain=\(dom.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? dom)") }
            if let tid = args["tabId"] as? String { qs.append("tabId=\(tid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tid)") }
            let qsStr = qs.isEmpty ? "" : "?" + qs.joined(separator: "&")

            if action == "get" {
                callNomad(method: "GET", path: "/cookies\(qsStr)") { res, err in respondTool(id: id, res: res, error: err) }
            } else if action == "clear" {
                callNomad(method: "DELETE", path: "/cookies\(qsStr)") { res, err in respondTool(id: id, res: res, error: err) }
            } else {
                callNomad(method: "POST", path: "/cookies", body: args) { res, err in respondTool(id: id, res: res, error: err) }
            }

        case "nomad_screenshot":
            var qs: [String] = []
            if let l = args["labeled"] as? Bool, l { qs.append("labeled=true") }
            if let el = args["elementId"] as? String { qs.append("elementId=\(el.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? el)") }
            if let clip = args["clip"] as? [String: Any],
               let x = clip["x"], let y = clip["y"], let w = clip["width"], let h = clip["height"] {
                qs.append("clip=\(x),\(y),\(w),\(h)")
            }
            if let tid = args["tabId"] as? String { qs.append("tabId=\(tid.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tid)") }
            let path = qs.isEmpty ? "/screenshot" : "/screenshot?" + qs.joined(separator: "&")
            callNomadRaw(method: "GET", path: path) { data, contentType, err in
                if let err = err {
                    sendToolText(id: id, text: err, isError: true)
                    return
                }
                guard let data = data, (contentType?.contains("image") == true || data.prefix(8) == Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) else {
                    let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "Screenshot capture failed"
                    sendToolText(id: id, text: text, isError: true)
                    return
                }
                let base64 = data.base64EncodedString()
                let result: [String: Any] = [
                    "content": [
                        [
                            "type": "image",
                            "data": base64,
                            "mimeType": "image/png"
                        ]
                    ],
                    "isError": false
                ]
                sendResponse(id: id, result: result)
            }

        case "nomad_evaluate":
            callNomad(method: "POST", path: "/evaluate", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_dialog":
            callNomad(method: "POST", path: "/dialog", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_console":
            var qs: [String] = []
            if let c = args["clear"] as? Bool, c { qs.append("clear=true") }
            if let lvl = args["level"] as? String { qs.append("level=\(lvl)") }
            if let tid = args["tabId"] as? String { qs.append("tabId=\(tid)") }
            let path = qs.isEmpty ? "/console" : "/console?" + qs.joined(separator: "&")
            callNomad(method: "GET", path: path) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_network":
            var qs: [String] = []
            if let c = args["clear"] as? Bool, c { qs.append("clear=true") }
            if let sf = args["statusFilter"] as? String { qs.append("statusFilter=\(sf)") }
            if let tid = args["tabId"] as? String { qs.append("tabId=\(tid)") }
            let path = qs.isEmpty ? "/network" : "/network?" + qs.joined(separator: "&")
            callNomad(method: "GET", path: path) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_downloads":
            var path = "/downloads"
            if let limit = args["limit"] as? Int {
                path += "?limit=\(limit)"
            }
            callNomad(method: "GET", path: path) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        case "nomad_wait_for_download":
            callNomad(method: "POST", path: "/downloads/wait", body: args) { res, err in
                respondTool(id: id, res: res, error: err)
            }

        default:
            sendError(id: id, code: -32601, message: "Unknown tool: \(name)")
        }
    }

    private static func callNomadHTTP(method: String, path: String, body: [String: Any]? = nil, completion: @escaping (Data?, HTTPURLResponse?, Error?) -> Void) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            completion(nil, nil, NSError(domain: "NomadMCP", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 35.0

        if let token = loadToken() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if let body = body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }

        var resultData: Data? = nil
        var resultResponse: HTTPURLResponse? = nil
        var resultError: Error? = nil

        let semaphore = DispatchSemaphore(value: 0)
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response as? HTTPURLResponse
            resultError = error
            semaphore.signal()
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 35.0)

        completion(resultData, resultResponse, resultError)
    }

    private static func callNomad(method: String, path: String, body: [String: Any]? = nil, completion: @escaping (Any?, String?) -> Void) {
        callNomadHTTP(method: method, path: path, body: body) { data, _, error in
            if let error = error as NSError? {
                if error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotConnectToHost {
                    completion(nil, "Could not connect to Nomad browser engine at http://127.0.0.1:\(port) (ECONNREFUSED). Nomad browser is not currently running. Please launch Nomad to enable automation.")
                } else {
                    completion(nil, "Network error: \(error.localizedDescription)")
                }
                return
            }
            guard let data = data else {
                completion(nil, "Empty response from Nomad")
                return
            }
            if let json = try? JSONSerialization.jsonObject(with: data) {
                completion(json, nil)
            } else if let text = String(data: data, encoding: .utf8) {
                completion(text, nil)
            } else {
                completion(nil, "Unparseable response")
            }
        }
    }

    private static func callNomadRaw(method: String, path: String, completion: @escaping (Data?, String?, String?) -> Void) {
        callNomadHTTP(method: method, path: path) { data, response, error in
            if let error = error {
                completion(nil, nil, error.localizedDescription)
                return
            }
            let contentType = response?.value(forHTTPHeaderField: "Content-Type")
            completion(data, contentType, nil)
        }
    }

    private static func respondTool(id: Any?, res: Any?, error: String?) {
        if let error = error {
            sendToolText(id: id, text: error, isError: true)
            return
        }
        if let dict = res as? [String: Any] {
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted]),
               let str = String(data: data, encoding: .utf8) {
                sendToolText(id: id, text: str, isError: dict["success"] as? Bool == false)
                return
            }
        }
        sendToolText(id: id, text: "\(res ?? "")", isError: false)
    }

    private static func sendToolText(id: Any?, text: String, isError: Bool = false) {
        let result: [String: Any] = [
            "content": [
                [
                    "type": "text",
                    "text": text
                ]
            ],
            "isError": isError
        ]
        sendResponse(id: id, result: result)
    }

    private static func sendResponse(id: Any?, result: Any) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result
        ]
        if let id = id { msg["id"] = id }
        outputJSON(msg)
    }

    private static func sendError(id: Any?, code: Int, message: String) {
        var msg: [String: Any] = [
            "jsonrpc": "2.0",
            "error": [
                "code": code,
                "message": message
            ]
        ]
        if let id = id { msg["id"] = id }
        outputJSON(msg)
    }

    private static func outputJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        var out = data
        out.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(out)
    }

    // MARK: - Tool Definitions Manifest
    private static let toolsManifest: [[String: Any]] = [
        [
            "name": "nomad_status",
            "description": "Check if Nomad browser engine is active, get version, tab counts, active page info, and engine capabilities.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_tabs",
            "description": "List all open tabs in Nomad with their ID, title, URL, active state, and loading status.",
            "inputSchema": [
                "type": "object",
                "properties": [:] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_new_tab",
            "description": "Open a new tab in Nomad. Optionally provide a URL to load immediately.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "URL to navigate to (optional)"],
                    "select": ["type": "boolean", "description": "Whether to switch to the new tab immediately (default true)"],
                    "isIncognito": ["type": "boolean", "description": "Open as incognito / private tab (default false)"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_switch_tab",
            "description": "Switch the active focused tab in Nomad by tab ID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Tab UUID string"]
                ] as [String: Any],
                "required": ["id"],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_close_tab",
            "description": "Close a tab in Nomad by tab ID.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "id": ["type": "string", "description": "Tab UUID string"]
                ] as [String: Any],
                "required": ["id"],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_navigate",
            "description": "Navigate the active tab to a new URL, or navigate browser history (back, forward, reload).",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "url": ["type": "string", "description": "Complete destination URL (e.g. https://github.com)"],
                    "action": [
                        "type": "string",
                        "enum": ["url", "back", "forward", "reload"],
                        "description": "Navigation action. If not specified, defaults to 'url'."
                    ] as [String: Any],
                    "allowLocalFiles": [
                        "type": "boolean",
                        "description": "Explicitly allow navigation to file:// URLs (default false)"
                    ]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_snapshot",
            "description": "Capture a token-optimized semantic perception tree (typically 300–1,200 tokens depending on page density, vs 50k–100k+ raw HTML). Extracts visible interactive elements, semantic headings (h1-h3), text content (list items, paragraphs, table cells), and images across light and Shadow DOM with assigned IDs ([e1], [e2], ...), bounding coordinates, tag names, roles, accessible text, image src URLs, and occlusion states.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "number", "description": "Maximum number of elements to include in semantic tree (default 100)"],
                    "offset": ["type": "number", "description": "Starting offset for element pagination in dense pages (default 0)"],
                    "viewportOnly": ["type": "boolean", "description": "When true, only include elements currently inside the visible viewport"],
                    "includeText": ["type": "boolean", "description": "When true (default), include non-interactive text content (li, p, td, th) for outcome verification"],
                    "role": ["type": "string", "description": "Optional filter: match elements by role or tag (e.g. 'button', 'input', 'heading')"],
                    "text": ["type": "string", "description": "Optional filter: case-insensitive substring match against element text/value/label"],
                    "mode": ["type": "string", "enum": ["text", "json"], "description": "Perception output format. 'text' returns compact markdown summary; 'json' returns raw element array (default: 'text')"] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional tab UUID to inspect instead of the active tab"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_action",
            "description": "Execute an atomic interaction in the active tab (click, hover, type, clear, press key chord, selectOption, scroll, drag, highlight, upload). Best used with elementId from nomad_snapshot (e.g. 'e1') or CSS selector fallback. Fully compatible with React controlled components.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "type": [
                        "type": "string",
                        "enum": ["click", "hover", "type", "clear", "press", "selectOption", "scroll", "drag", "highlight", "upload", "native_click", "native_hover", "native_type", "native_press", "native_drag"],
                        "description": "Type of action to execute"
                    ] as [String: Any],
                    "elementId": ["type": "string", "description": "Target element ID from nomad_snapshot (e.g. 'e1', 'e2', or subframe 'f1:e1')"],
                    "selector": ["type": "string", "description": "CSS selector fallback if elementId is not used (e.g. '.todo-list li .toggle')"],
                    "text": ["type": "string", "description": "Text to enter (for 'type' action) or key name / chord (for 'press' action, e.g. 'Enter', 'Meta+A')"],
                    "native": [
                        "type": "boolean",
                        "description": "Dispatch native AppKit/CoreGraphics hardware input (sets isTrusted: true for Canvas, WebGL, Monaco, and verification sliders)"
                    ],
                    "paths": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Array of local file paths (absolute or tilde ~/...) to upload (for 'upload' action)"
                    ] as [String: Any],
                    "optionValue": ["type": "string", "description": "Option value to choose for 'selectOption'"],
                    "optionText": ["type": "string", "description": "Option visible text to choose for 'selectOption'"],
                    "x": ["type": "number", "description": "Viewport X coordinate fallback"],
                    "y": ["type": "number", "description": "Viewport Y coordinate fallback"],
                    "toX": ["type": "number", "description": "Destination X coordinate for drag action"],
                    "toY": ["type": "number", "description": "Destination Y coordinate for drag action"],
                    "scrollDeltaY": ["type": "number", "description": "Pixels to scroll down (positive) or up (negative) for 'scroll'"],
                    "scrollDeltaX": ["type": "number", "description": "Pixels to scroll right (positive) or left (negative) for 'scroll'"],
                    "direction": ["type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction fallback"] as [String: Any],
                    "amount": ["type": "number", "description": "Pixels to scroll for direction fallback"],
                    "force": ["type": "boolean", "description": "When true, bypass occlusion check and click target directly even if covered by an overlay"],
                    "submit": ["type": "boolean", "description": "When true, submit form or press Enter after typing"],
                    "blur": ["type": "boolean", "description": "When true, blur element after typing to trigger commit"],
                    "key": ["type": "string", "description": "Key name or chord to press (e.g. 'Enter', 'Tab', 'Escape', 'Meta+A')"],
                    "dialogPolicy": [
                        "type": "string",
                        "enum": ["accept", "dismiss", "wait"],
                        "description": "Optional dialog response policy to apply before executing action ('accept', 'dismiss', or 'wait' to hold)"
                    ] as [String: Any],
                    "dialogResponse": ["type": "string", "description": "Optional default response string for prompt dialogs"],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "required": ["type"],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_upload",
            "description": "Upload one or more local files to a file input, upload dropzone, or label on the active page without triggering modal system dialogs.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "elementId": ["type": "string", "description": "Element reference from nomad_snapshot (e.g. 'e1') or CSS selector of the file input/button"],
                    "paths": [
                        "type": "array",
                        "items": ["type": "string"],
                        "description": "Array of local file paths (absolute or tilde ~/...) to upload"
                    ] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "required": ["elementId", "paths"],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_wait",
            "description": "Wait for DOM mutation stability, a specific CSS selector, URL pattern, network requests to become idle, navigation to complete, or a timeout before continuing execution.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mode": [
                        "type": "string",
                        "enum": ["stability", "selector", "timeout", "networkidle", "navigation", "url"],
                        "description": "Wait mode. Default: stability."
                    ] as [String: Any],
                    "selector": ["type": "string", "description": "CSS selector to wait for (if provided, mode defaults to 'selector')"],
                    "urlPattern": ["type": "string", "description": "Substring or regex pattern to wait for in active URL (for 'navigation' or 'url' mode)"],
                    "quietMs": ["type": "number", "description": "Milliseconds of DOM mutation silence required for 'stability' (default: 250)"],
                    "timeoutMs": ["type": "number", "description": "Maximum milliseconds to wait before timing out (default: 5000)"],
                    "durationMs": ["type": "number", "description": "Duration in milliseconds for 'timeout' mode (default: 1000)"],
                    "idleMs": ["type": "number", "description": "Milliseconds of network silence required for 'networkidle' (default: 500)"],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_cookies",
            "description": "Inspect, set, or clear session cookies in the active browser session for authentication and state management.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "action": [
                        "type": "string",
                        "enum": ["get", "set", "clear"],
                        "description": "Cookie operation (default: get)"
                    ] as [String: Any],
                    "allDomains": ["type": "boolean", "description": "When true, inspect or clear cookies across all domains, not just the active tab domain"],
                    "name": ["type": "string", "description": "Cookie name (for 'set')"],
                    "value": ["type": "string", "description": "Cookie value (for 'set')"],
                    "domain": ["type": "string", "description": "Domain name for the cookie"],
                    "path": ["type": "string", "description": "Path for the cookie (default: '/')"],
                    "isSecure": ["type": "boolean", "description": "Secure cookie flag"],
                    "isHTTPOnly": ["type": "boolean", "description": "HTTP-only cookie flag"],
                    "expires": ["type": "number", "description": "Unix timestamp in seconds when the cookie expires"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_screenshot",
            "description": "Capture a GPU screenshot of the active tab. Set labeled=true to overlay numbered element badges [1], [2]. Set elementId (e.g. 'e2') or clip to crop to a specific element or region for cheaper vision tokens.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "labeled": ["type": "boolean", "description": "If true, renders vision-grounding element number badges over interactive nodes"],
                    "elementId": ["type": "string", "description": "Optional element ID from nomad_snapshot to crop screenshot to (e.g. 'e2')"],
                    "clip": [
                        "type": "object",
                        "properties": [
                            "x": ["type": "number"],
                            "y": ["type": "number"],
                            "width": ["type": "number"],
                            "height": ["type": "number"]
                        ] as [String: Any],
                        "required": ["x", "y", "width", "height"],
                        "description": "Optional viewport coordinates rectangle to crop screenshot to"
                    ] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_evaluate",
            "description": "Evaluate an arbitrary JavaScript expression in the active tab and return the output.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "script": ["type": "string", "description": "JavaScript code to execute"],
                    "world": [
                        "type": "string",
                        "enum": ["page", "isolated"],
                        "description": "Execution context world (default: page)"
                    ] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "required": ["script"],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_dialog",
            "description": "Inspect the last JavaScript dialog (alert/confirm/prompt) or configure response policy ('accept' | 'dismiss' | 'wait').",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "policy": [
                        "type": "string",
                        "enum": ["accept", "dismiss", "wait"],
                        "description": "Response policy for JavaScript dialogs ('accept', 'dismiss', or 'wait' to hold for inspection; default 'dismiss')"
                    ] as [String: Any],
                    "action": [
                        "type": "string",
                        "enum": ["accept", "dismiss"],
                        "description": "Immediate resolution action for any currently waiting dialog ('accept' | 'dismiss')"
                    ] as [String: Any],
                    "response": ["type": "string", "description": "Default text response for window.prompt dialogs"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_console",
            "description": "Inspect recent console log messages (log, warn, error) emitted by the page. Useful for diagnosing frontend issues without blind waits.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "clear": ["type": "boolean", "description": "When true, clears the console log buffer after reading (default: false)"],
                    "level": ["type": "string", "enum": ["all", "log", "warn", "error"], "description": "Filter by log level (default: all)"] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_network",
            "description": "Inspect recent HTTP network requests (fetch/XHR) executed by the page, including methods, URLs, status codes, latencies, and errors.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "clear": ["type": "boolean", "description": "When true, clears the network log buffer after reading (default: false)"],
                    "statusFilter": ["type": "string", "enum": ["all", "errors", "success"], "description": "Filter requests (default: all)"] as [String: Any],
                    "tabId": ["type": "string", "description": "Optional target tab UUID"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_downloads",
            "description": "List recent file downloads initiated in Nomad browser, showing destination paths, sizes, and states.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Maximum number of recent downloads to return (default: 20)"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ],
        [
            "name": "nomad_wait_for_download",
            "description": "Wait for an active or impending file download to complete, returning the local disk path, file size, and SHA-256 checksum.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "timeoutMs": ["type": "integer", "description": "Maximum time to wait in milliseconds (default: 15000)"],
                    "since": ["type": "string", "description": "Optional ISO8601 timestamp; returns any download completed after this time"]
                ] as [String: Any],
                "additionalProperties": false
            ] as [String: Any]
        ]
    ]
}
