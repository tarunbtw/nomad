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
        
        // Enable modern web preferences
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        config.defaultWebpagePreferences = prefs
        
        // Developer extras for Web Inspector
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        
        // User content controller for script message handlers and future extensions
        config.userContentController = WKUserContentController()

        return config
    }
}
