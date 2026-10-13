//
//  WebKitPool.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import WebKit

/// Manages WebKit resources, configurations, and extension-readiness.
enum WebKitPool {
    /// Standard user-agent matching the system Safari version to prevent Google CAPTCHAs and compatibility warnings.
    static let customUserAgent: String = {
        let osVersion = ProcessInfo.processInfo.operatingSystemVersion.majorVersion
        let safariVer = osVersion >= 26 ? "\(osVersion).0" : "\(osVersion + 3).0"
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(safariVer) Safari/605.1.15"
    }()

    /// Creates a standardized WKWebViewConfiguration.
    /// Ready for WebExtensions (WKWebExtensionController) and custom user scripts.
    @MainActor
    static func makeConfiguration(isIncognito: Bool = false) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        if isIncognito {
            config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        }
        ExtensionManager.shared.attach(config)
        
        // Enable modern web preferences with full desktop mode
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = prefs
        
        // Developer extras for Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        // Throttle inactive and background tabs to stop CPU waste and heat
        config.preferences.inactiveSchedulingPolicy = .throttle
        // Enable HTML5 video fullscreen expansion
        config.preferences.isElementFullscreenEnabled = true
        // Automatically upgrade known hosts to HTTPS
        config.upgradeKnownHostsToHTTPS = true
        
        // Use the configuration's userContentController directly so WebExtensions stay bound
        let ucc = config.userContentController
        ContentBlockerService.shared.attach(to: ucc)
        
        // Suppress horizontal elastic overscroll bounce and ensure GitHub avatars render as 1:1 circles
        let globalFixes = """
        (function() {
            const s = document.createElement('style');
            s.id = 'nomad-viewport-fixes';
            s.textContent = `
                html, body {
                    overscroll-behavior-x: none !important;
                }
                .avatar-user, .user-profile-mini-avatar img, img.avatar {
                    aspect-ratio: 1 / 1 !important;
                    border-radius: 50% !important;
                    object-fit: cover !important;
                }
            `;
            if (document.head) {
                document.head.appendChild(s);
            } else {
                document.addEventListener('DOMContentLoaded', () => {
                    if (document.head && !document.getElementById('nomad-viewport-fixes')) {
                        document.head.appendChild(s);
                    }
                });
            }
        })();
        """
        let userScript = WKUserScript(source: globalFixes, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ucc.addUserScript(userScript)

        // Capture console output for Nomad DevX Console
        let consoleInterceptor = """
        (function() {
            if (window.__nomad_console_hooked) return;
            window.__nomad_console_hooked = true;
            const origLog = console.log;
            const origWarn = console.warn;
            const origError = console.error;
            function send(lvl, args) {
                try {
                    const str = Array.from(args).map(a => {
                        if (typeof a === 'object') {
                            try { return JSON.stringify(a); } catch(e) { return String(a); }
                        }
                        return String(a);
                    }).join(' ');
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadConsole) {
                        window.webkit.messageHandlers.nomadConsole.postMessage({ level: lvl, message: str });
                    }
                } catch(e) {}
            }
            console.log = function(...args) { origLog.apply(console, args); send('log', args); };
            console.warn = function(...args) { origWarn.apply(console, args); send('warn', args); };
            console.error = function(...args) { origError.apply(console, args); send('error', args); };
        })();
        """
        ucc.addUserScript(WKUserScript(source: consoleInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        // Capture fetch and XMLHttpRequest network activity for Nomad DevX Network Tab
        let networkInterceptor = """
        (function() {
            if (window.__nomad_network_hooked) return;
            window.__nomad_network_hooked = true;

            function sendNet(entry) {
                try {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.nomadNetwork) {
                        window.webkit.messageHandlers.nomadNetwork.postMessage(entry);
                    }
                } catch(e) {}
            }

            // Hook window.fetch
            const origFetch = window.fetch;
            if (origFetch) {
                window.fetch = async function(...args) {
                    const startTime = performance.now();
                    let method = 'GET';
                    let url = '';
                    try {
                        if (typeof args[0] === 'string') {
                            url = args[0];
                        } else if (args[0] && args[0].url) {
                            url = args[0].url;
                            if (args[0].method) method = String(args[0].method).toUpperCase();
                        }
                        if (args[1] && args[1].method) {
                            method = String(args[1].method).toUpperCase();
                        }
                    } catch(e) {}

                    try {
                        const res = await origFetch.apply(this, args);
                        const duration = Math.round(performance.now() - startTime);
                        sendNet({
                            method: method,
                            url: url || (res ? res.url : ''),
                            status: res ? res.status : 200,
                            duration: duration,
                            type: 'fetch'
                        });
                        return res;
                    } catch(err) {
                        const duration = Math.round(performance.now() - startTime);
                        sendNet({
                            method: method,
                            url: url,
                            status: 0,
                            duration: duration,
                            type: 'fetch',
                            error: err ? err.message : 'Network error'
                        });
                        throw err;
                    }
                };
            }

            // Hook XMLHttpRequest
            const origOpen = XMLHttpRequest.prototype.open;
            const origSend = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                this.__nomad_method = (method || 'GET').toUpperCase();
                this.__nomad_url = url;
                return origOpen.apply(this, [method, url, ...rest]);
            };
            XMLHttpRequest.prototype.send = function(...args) {
                const startTime = performance.now();
                const xhr = this;
                this.addEventListener('loadend', function() {
                    const duration = Math.round(performance.now() - startTime);
                    sendNet({
                        method: xhr.__nomad_method || 'GET',
                        url: xhr.__nomad_url || '',
                        status: xhr.status || 0,
                        duration: duration,
                        type: 'xhr'
                    });
                }, { once: true });
                return origSend.apply(this, args);
            };
        })();
        """
        ucc.addUserScript(WKUserScript(source: networkInterceptor, injectionTime: .atDocumentStart, forMainFrameOnly: false))

        return config
    }
}
