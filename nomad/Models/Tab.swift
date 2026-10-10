//
//  Tab.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import WebKit
import Combine

/// Represents an individual browser tab.
/// Owns its WKWebView instance so switching tabs is instant and preserves scroll state.
@MainActor
final class Tab: NSObject, Identifiable, ObservableObject {
    let id: UUID
    
    @Published var url: URL?
    @Published var title: String
    @Published var isLoading: Bool = false
    @Published var estimatedProgress: Double = 0.0
    @Published var canGoBack: Bool = false
    @Published var canGoForward: Bool = false
    @Published var isBlank: Bool = true
    
    /// The retained web view for this tab.
    let webView: WKWebView
    
    /// Optional hook called when web content requests opening a new window (e.g. target="_blank").
    var onOpenURLInNewTab: ((URL) -> Void)?
    
    private var observers: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), initialURL: URL? = nil) {
        self.id = id
        self.url = initialURL
        self.title = "New Tab"
        
        let config = WebKitPool.makeConfiguration()
        self.webView = WKWebView(frame: .zero, configuration: config)
        self.webView.customUserAgent = WebKitPool.customUserAgent
        
        super.init()
        
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        
        setupObservers()
        
        if let initialURL = initialURL {
            load(url: initialURL)
        }
    }

    deinit {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
    }

    /// Loads a user-typed string (resolved via URLParser).
    func load(text: String) {
        let destination = URLParser.parse(text)
        load(url: destination)
    }

    /// Loads a specific URL.
    func load(url: URL) {
        self.url = url
        self.isBlank = (url.absoluteString == "about:blank")
        let request = URLRequest(url: url)
        webView.load(request)
    }

    func goBack() {
        if webView.canGoBack {
            webView.goBack()
        }
    }

    func goForward() {
        if webView.canGoForward {
            webView.goForward()
        }
    }

    func reload() {
        webView.reload()
    }

    // MARK: - KVO Observers
    private func setupObservers() {
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                let newTitle = wv.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self?.title = newTitle.isEmpty ? (self?.url?.host ?? "New Tab") : newTitle
            }
        })

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.url = wv.url
                self?.isBlank = (wv.url == nil || wv.url?.absoluteString == "about:blank")
            }
        })

        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.isLoading = wv.isLoading
            }
        })

        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.estimatedProgress = wv.estimatedProgress
            }
        })

        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.canGoBack = wv.canGoBack
            }
        })

        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            Task { @MainActor in
                self?.canGoForward = wv.canGoForward
            }
        })
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate
extension Tab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.isLoading = false
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let targetURL = navigationAction.request.url {
            if let onOpenURLInNewTab = self.onOpenURLInNewTab {
                onOpenURLInNewTab(targetURL)
            } else {
                self.load(url: targetURL)
            }
        }
        return nil
    }
}
