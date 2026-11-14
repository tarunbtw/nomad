//
//  Tab+Navigation.swift
//  dino
//
//  Created by tarun on 10/10/26.
//

import WebKit
import UniformTypeIdentifiers

// MARK: - WKNavigationDelegate
extension Tab: WKNavigationDelegate {
    // MARK: - Navigation Policy & Security Scheme Validation
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        // Shift-click link hover preview (Peek)
        if navigationAction.modifierFlags.contains(.shift),
           navigationAction.navigationType == .linkActivated,
           let targetURL = navigationAction.request.url,
           ["http", "https"].contains(targetURL.scheme?.lowercased() ?? "") {
            self.onRequestPeek?(targetURL)
            decisionHandler(.cancel, preferences)
            return
        }

        // Security scheme & network block validation
        if let targetURL = navigationAction.request.url {
            let urlString = targetURL.absoluteString
            for pattern in self.blockedURLPatterns {
                if urlString.contains(pattern) || (pattern.contains("*") && matchesGlob(urlString, pattern: pattern)) {
                    appendConsoleEntry(level: .warn, message: "[Network Block] Cancelled navigation matching '\(pattern)': \(urlString)")
                    decisionHandler(.cancel, preferences)
                    return
                }
            }

            // Domain allowlist policy enforcement
            if let host = targetURL.host, !host.isEmpty, !DinoAgentServer.shared.isDomainAllowed(host) {
                DinoAgentServer.shared.recordSecurityAudit(type: "navigation_blocked", message: "Navigation to unlisted domain '\(host)' blocked by policy", isBlocked: true)
                appendConsoleEntry(level: .warn, message: "[Security Policy] Blocked navigation to '\(host)' not in domain allowlist")
                decisionHandler(.cancel, preferences)
                return
            }

            let scheme = targetURL.scheme?.lowercased() ?? ""
            if scheme == "file" {
                // Allow file:// if explicitly initiated by app/agent via load(url:), or already browsing local files
                if allowNextFileNavigation || webView.url == nil || webView.url?.absoluteString == "about:blank" || webView.url?.isFileURL == true {
                    decisionHandler(.allow, preferences)
                    return
                } else {
                    // Disallow untrusted remote web pages from navigating to local file URLs
                    decisionHandler(.cancel, preferences)
                    return
                }
            } else if scheme == "dino" && webView.url?.scheme != "dino" {
                decisionHandler(.cancel, preferences)
                return
            }
        }

        decisionHandler(.allow, preferences)
    }

    // MIME type & Content-Disposition check for downloads (.zip, .dmg, .pkg, images with attachment header, etc.)
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // A redirect (3xx) has nowhere to be shown and carries no content of its own, but must be followed
        if let http = navigationResponse.response as? HTTPURLResponse, (300...399).contains(http.statusCode) {
            decisionHandler(.allow)
            return
        }
        // A server that says "attachment" means a file to keep (like Wallhaven wallpaper downloads)
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            decisionHandler(.download)
            return
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    // Connect WebKit downloads to DownloadManager
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        let originalURL = navigationAction.request.url ?? URL(string: "about:blank")!
        DownloadManager.shared.register(download, from: originalURL)
        if self.isBlank || self.webView.url == nil {
            onRequestCloseTab?()
        }
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        let originalURL = navigationResponse.response.url ?? URL(string: "about:blank")!
        let suggested = navigationResponse.response.suggestedFilename ?? "download"
        DownloadManager.shared.register(download, from: originalURL, suggestedFilename: suggested)
        if self.isBlank || self.webView.url == nil {
            onRequestCloseTab?()
        }
    }

    @objc(_webView:contextMenuDidCreateDownload:)
    func webView(_ webView: WKWebView, contextMenuDidCreateDownload download: WKDownload) {
        let originalURL = webView.url ?? URL(string: "about:blank")!
        DownloadManager.shared.register(download, from: originalURL)
    }

    // TLS Certificate Validation & Security Challenges
    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            if let serverTrust = challenge.protectionSpace.serverTrust {
                var secError: CFError?
                let isValid = SecTrustEvaluateWithError(serverTrust, &secError)
                if isValid {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }

                // Prompt user for untrusted / self-signed certificate (or bypass modal in headless mode)
                let host = challenge.protectionSpace.host
                if DinoHeadlessManager.isHeadless {
                    // Headless automation automatically trusts localhost/local certs without GUI blocking
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Security Warning: Untrusted Certificate"
                alert.informativeText = "The certificate for \"\(host)\" is invalid or self-signed. Visiting this site may compromise your privacy.\n\nDo you want to continue anyway?"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "Cancel")
                alert.addButton(withTitle: "Continue Anyway")

                let response = alert.runModal()
                if response == .alertSecondButtonReturn {
                    completionHandler(.useCredential, URLCredential(trust: serverTrust))
                    return
                }
            }
        }
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let navSeq = sequence(for: navigation) ?? self.navigationSeq
        guard navSeq >= self.navigationSeq else { return }
        if let curNav = self.currentNavigation, navigation != curNav {
            return
        }
        self.allowNextFileNavigation = false
        self.isLoading = false
        self.committedNavigationSeq = navSeq
        self.lastNavigationError = nil
        self.lastNavigationFinishTime = Date()
        self.syncMockRoutes()
        self.updateNavigationState()
        self.checkMediaPlayback()
        if let start = self.lastNavigationStartTime {
            let elapsed = Int(Date().timeIntervalSince(start) * 1000.0)
            if let idx = self.networkEntries.lastIndex(where: { $0.type == "document" }) {
                let old = self.networkEntries[idx]
                self.networkEntries[idx] = NetworkEntry(
                    id: old.id,
                    method: old.method,
                    url: webView.url?.absoluteString ?? old.url,
                    status: 200,
                    durationMs: max(1, elapsed),
                    timestamp: old.timestamp,
                    type: "document",
                    error: nil
                )
            }
        }
        DinoAgentServer.shared.broadcastEvent(name: "navigation", payload: [
            "tabId": self.id.uuidString,
            "url": webView.url?.absoluteString ?? self.url?.absoluteString ?? "",
            "title": webView.title ?? self.title,
            "isLoading": false
        ])
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
        if let currentURL = webView.url, !self.isShowingOfflinePage {
            fetchFavicon(for: currentURL)

            // Record visited page in HistoryStore (only for user profile, bypassed in Incognito mode and Agent profiles)
            if !self.isIncognito && self.profileType == .user {
                HistoryStore.shared.addVisit(url: currentURL, title: self.title)
            }

            // Apply persistently zapped elements for this domain
            if let host = currentURL.host {
                let css = ZapperStore.shared.cssRule(for: host)
                if !css.isEmpty,
                   let cssData = try? JSONSerialization.data(withJSONObject: [css]),
                   let jsonArray = String(data: cssData, encoding: .utf8) {
                    let injectScript = """
                    (function() {
                        let s = document.getElementById('dino-zapped-rules');
                        if (!s) {
                            s = document.createElement('style');
                            s.id = 'dino-zapped-rules';
                            (document.head || document.documentElement).appendChild(s);
                        }
                        s.textContent = (\(jsonArray))[0];
                    })();
                    """
                    webView.evaluateJavaScript(injectScript, completionHandler: nil)
                }
            }

            let js = "document.querySelector(\"link[rel~='icon'], link[rel='shortcut icon']\")?.href || \"\""
            webView.evaluateJavaScript(js) { [weak self] result, _ in
                guard let self = self,
                      let hrefString = result as? String,
                      !hrefString.isEmpty,
                      let iconURL = URL(string: hrefString),
                      let host = currentURL.host else { return }
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    if let image = await FaviconService.shared.loadFavicon(fromDirectURL: iconURL, host: host) {
                        if self.url?.host == host || self.webView.url?.host == host {
                            self.favicon = image
                        }
                    }
                }
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        let navSeq = sequence(for: navigation) ?? self.navigationSeq
        guard navSeq >= self.navigationSeq else { return }
        self.committedNavigationSeq = navSeq
        self.lastNavigationError = nil
        self.syncMockRoutes()
        self.updateNavigationState()
        self.checkMediaPlayback()
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        let navSeq = sequence(for: navigation) ?? self.navigationSeq
        guard navSeq >= self.navigationSeq else { return }
        self.currentNavigation = navigation
        self.lastNavigationStartTime = Date()
        self.lastNavigationError = nil
        self.isShowingOfflinePage = false

        let targetUrl = webView.url?.absoluteString ?? self.url?.absoluteString ?? ""
        let docEntry = NetworkEntry(
            method: "GET",
            url: targetUrl,
            status: 200,
            durationMs: 0,
            type: "document"
        )
        if self.networkEntries.count > 300 {
            self.networkEntries.removeFirst(50)
        }
        self.networkEntries.append(docEntry)

        DinoAgentServer.shared.broadcastEvent(name: "navigationStart", payload: [
            "tabId": self.id.uuidString,
            "url": targetUrl
        ])
        self.updateNavigationState()
    }

    private func isSupersededOrCancelled(_ error: Error, navigation: WKNavigation!) -> Bool {
        let nsErr = error as NSError
        if nsErr.domain == NSURLErrorDomain && nsErr.code == NSURLErrorCancelled {
            return true
        }
        if let navSeq = sequence(for: navigation), navSeq < self.navigationSeq {
            return true
        }
        if let curNav = self.currentNavigation, navigation != curNav {
            return true
        }
        return false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if isSupersededOrCancelled(error, navigation: navigation) {
            print("Tab Navigation failure ignored (superseded or cancelled): \(error.localizedDescription)")
            return
        }

        self.allowNextFileNavigation = false
        self.isLoading = false
        self.lastNavigationFinishTime = Date()
        self.lastNavigationError = error.localizedDescription
        self.lastFailedNavigationSeq = self.navigationSeq

        if DinoOfflinePage.isOfflineError(error) {
            self.isShowingOfflinePage = true
            self.title = "No Internet — Dino"
            let targetURL = self.url ?? URL(string: "about:blank")!
            let offlineHTML = DinoOfflinePage.html(for: targetURL, error: error)
            self.webView.loadHTMLString(offlineHTML, baseURL: targetURL)
            return
        }

        self.title = "Error: \(error.localizedDescription)"
        DinoAgentServer.shared.broadcastEvent(name: "navigationError", payload: [
            "tabId": self.id.uuidString,
            "error": error.localizedDescription
        ])
        print("Tab Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // Ignore cancellations from superseded in-flight navigations so they do not wipe out allowNextFileNavigation or trigger false fallbacks
        if isSupersededOrCancelled(error, navigation: navigation) {
            print("Tab Provisional navigation failure ignored (superseded or cancelled): \(error.localizedDescription)")
            return
        }

        // Fallback for file:// URLs that WebKit actually rejects via loadFileURL (e.g. extensionless or unsupported format)
        if let currentURL = self.url, currentURL.isFileURL, self.allowNextFileNavigation, let data = try? Data(contentsOf: currentURL) {
            let ext = currentURL.pathExtension.lowercased()
            let mimeType = UTType(filenameExtension: ext)?.preferredMIMEType ?? "text/plain"
            print("Tab Provisional navigation failed on file URL with \(error.localizedDescription), falling back to data load (\(mimeType))")
            self.currentNavigation = self.webView.load(data, mimeType: mimeType, characterEncodingName: "utf-8", baseURL: currentURL)
            return
        }
        self.allowNextFileNavigation = false
        self.isLoading = false
        self.lastNavigationFinishTime = Date()
        self.lastNavigationError = error.localizedDescription
        self.lastFailedNavigationSeq = self.navigationSeq

        if DinoOfflinePage.isOfflineError(error) {
            self.isShowingOfflinePage = true
            self.title = "No Internet — Dino"
            let targetURL = self.url ?? URL(string: "about:blank")!
            let offlineHTML = DinoOfflinePage.html(for: targetURL, error: error)
            self.webView.loadHTMLString(offlineHTML, baseURL: targetURL)
            return
        }

        self.title = "Error: \(error.localizedDescription)"
        DinoAgentServer.shared.broadcastEvent(name: "navigationError", payload: [
            "tabId": self.id.uuidString,
            "error": error.localizedDescription
        ])
        print("Tab Provisional navigation failed: \(error.localizedDescription)")
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        self.isLoading = false
        print("Tab WebContent process terminated, automatically reloading...")
        webView.reload()
    }

    private func matchesGlob(_ string: String, pattern: String) -> Bool {
        let regexPattern = "^" + NSRegularExpression.escapedPattern(for: pattern).replacingOccurrences(of: "\\*", with: ".*") + "$"
        return (try? NSRegularExpression(pattern: regexPattern, options: .caseInsensitive))?.firstMatch(in: string, range: NSRange(string.startIndex..., in: string)) != nil
    }
}
