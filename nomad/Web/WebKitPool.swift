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
    static func makeConfiguration() -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        
        // Enable modern web preferences with full desktop mode
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        prefs.preferredContentMode = .desktop
        config.defaultWebpagePreferences = prefs
        
        // Developer extras for Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        // User content controller for script message handlers and future extensions
        let ucc = WKUserContentController()
        
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
        
        config.userContentController = ucc

        return config
    }
}
