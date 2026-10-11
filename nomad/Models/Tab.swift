//
//  Tab.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
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

    // MARK: - Fluid Two-Finger Swipe Navigation State
    enum SwipeDirection {
        case back
        case forward
    }

    struct SwipeGestureState {
        var direction: SwipeDirection
        var progress: CGFloat
        var distance: CGFloat
        var isTriggered: Bool
    }

    @Published var swipeState: SwipeGestureState? = nil
    
    /// The retained custom web view for this tab.
    let webView: BrowserWebView
    
    /// Optional hook called when web content requests opening a new window (e.g. target="_blank").
    var onOpenURLInNewTab: ((URL) -> Void)?
    
    private var observers: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), initialURL: URL? = nil) {
        self.id = id
        self.url = initialURL
        self.title = "New Tab"
        
        let config = WebKitPool.makeConfiguration()
        let webView = BrowserWebView(frame: NSRect(x: 0, y: 0, width: 1180, height: 730), configuration: config)
        webView.customUserAgent = WebKitPool.customUserAgent
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        webView.setMagnification(1.0, centeredAt: .zero)
        webView.pageZoom = 1.0
        self.webView = webView
        
        super.init()
        
        webView.tab = self
        self.webView.navigationDelegate = self
        self.webView.uiDelegate = self
        
        setupObservers()
        
        if let initialURL = initialURL {
            load(url: initialURL)
        }
    }

    // MARK: - Swipe Gesture Coordinator
    func updateSwipeGesture(direction: SwipeDirection, progress: CGFloat, distance: CGFloat, isTriggered: Bool) {
        self.swipeState = SwipeGestureState(
            direction: direction,
            progress: progress,
            distance: distance,
            isTriggered: isTriggered
        )
    }

    func cancelSwipeGesture() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            self.swipeState = nil
        }
    }

    func finishSwipeGesture(commit: Bool, direction: SwipeDirection) {
        if commit {
            withAnimation(.easeOut(duration: 0.2)) {
                self.swipeState = nil
            }
            if direction == .back {
                self.goBack()
            } else {
                self.goForward()
            }
        } else {
            cancelSwipeGesture()
        }
    }

    deinit {
        observers.forEach { $0.invalidate() }
        observers.removeAll()
    }

    var isInternalPage: Bool {
        url?.scheme == "nomad"
    }

    /// Loads a user-typed string (resolved via URLParser).
    func load(text: String) {
        let destination = URLParser.parse(text)
        load(url: destination)
    }

    /// Loads a specific URL.
    func load(url: URL) {
        self.url = url
        if url.scheme == "nomad" {
            self.isBlank = false
            self.isLoading = false
            self.title = (url.host == "tune") ? "Tune" : "Settings"
            return
        }

        self.isBlank = (url.absoluteString == "about:blank")
        webView.setMagnification(1.0, centeredAt: .zero)
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
        if isInternalPage { return }
        webView.reload()
    }

    func stopLoading() {
        webView.stopLoading()
    }

    // MARK: - Browser Page Zoom (Standards-compliant HTML reflow zoom: ⌘+, ⌘-, ⌘0)
    var currentZoom: Double {
        webView.pageZoom
    }

    func zoomIn() {
        guard !isInternalPage else { return }
        let next = min(webView.pageZoom + 0.1, 3.0)
        webView.pageZoom = (next * 10).rounded() / 10.0
    }

    func zoomOut() {
        guard !isInternalPage else { return }
        let next = max(webView.pageZoom - 0.1, 0.5)
        webView.pageZoom = (next * 10).rounded() / 10.0
    }

    func resetZoom() {
        guard !isInternalPage else { return }
        webView.pageZoom = 1.0
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
    }

    // MARK: - KVO Observers
    private func setupObservers() {
        observers.append(webView.observe(\.title, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let newTitle = wv.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            Task { @MainActor [weak self] in
                guard let self, !self.isInternalPage else { return }
                self.title = newTitle.isEmpty ? (self.url?.host ?? "New Tab") : newTitle
            }
        })

        observers.append(webView.observe(\.url, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let newURL = wv.url
            Task { @MainActor [weak self] in
                guard let self, !self.isInternalPage else { return }
                self.url = newURL
                self.isBlank = (newURL == nil || newURL?.absoluteString == "about:blank")
            }
        })

        observers.append(webView.observe(\.isLoading, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let loading = wv.isLoading
            Task { @MainActor [weak self] in
                self?.isLoading = loading
            }
        })

        observers.append(webView.observe(\.estimatedProgress, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let progress = wv.estimatedProgress
            Task { @MainActor [weak self] in
                self?.estimatedProgress = progress
            }
        })

        observers.append(webView.observe(\.canGoBack, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let canBack = wv.canGoBack
            Task { @MainActor [weak self] in
                self?.canGoBack = canBack
            }
        })

        observers.append(webView.observe(\.canGoForward, options: [.new]) { [weak self] wv, _ in
            guard let self else { return }
            let canForward = wv.canGoForward
            Task { @MainActor [weak self] in
                self?.canGoForward = canForward
            }
        })
    }
}

// MARK: - WKNavigationDelegate & WKUIDelegate
extension Tab: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        self.isLoading = false
        if webView.magnification != 1.0 {
            webView.setMagnification(1.0, centeredAt: .zero)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        print("Tab Navigation failed: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.isLoading = false
        print("Tab Provisional navigation failed: \(error.localizedDescription)")
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

// MARK: - Custom Browser WebView with Directional Axis Locking and Fluid Gestures
@MainActor
final class BrowserWebView: WKWebView {
    weak var tab: Tab?

    private enum ActiveScrollAxis {
        case none
        case vertical
        case horizontalSwipe
        case horizontalSuppressed
    }

    private var currentAxis: ActiveScrollAxis = .none
    private var accumulatedX: CGFloat = 0
    private var hasTriggeredHaptic: Bool = false

    override func scrollWheel(with event: NSEvent) {
        guard let tab = tab, event.hasPreciseScrollingDeltas else {
            super.scrollWheel(with: event)
            return
        }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY

        // Handle end or cancellation of the scroll gesture
        if event.phase == .ended || event.phase == .cancelled {
            if currentAxis == .horizontalSwipe {
                let direction: Tab.SwipeDirection = accumulatedX > 0 ? .back : .forward
                let shouldCommit = abs(accumulatedX) >= 55
                tab.finishSwipeGesture(commit: shouldCommit, direction: direction)
            }
            currentAxis = .none
            accumulatedX = 0
            hasTriggeredHaptic = false
            super.scrollWheel(with: event)
            return
        }

        // Detect axis when gesture begins
        if event.phase == .began {
            accumulatedX = 0
            hasTriggeredHaptic = false

            // If vertical motion is dominant, lock strictly to vertical axis to eliminate any diagonal wobble
            if abs(deltaY) >= abs(deltaX) {
                currentAxis = .vertical
            } else if abs(deltaX) > abs(deltaY) * 1.5 && abs(deltaX) > 1.5 {
                // Dominant horizontal motion
                if (deltaX > 0 && tab.canGoBack) || (deltaX < 0 && tab.canGoForward) {
                    currentAxis = .horizontalSwipe
                } else {
                    currentAxis = .horizontalSuppressed
                }
            } else {
                currentAxis = .none
            }
        }

        // Process active gestures
        switch currentAxis {
        case .horizontalSwipe:
            if event.phase == .changed {
                accumulatedX += deltaX

                // Cancel if user swipes back against the allowed navigation direction
                if (accumulatedX > 0 && !tab.canGoBack) || (accumulatedX < 0 && !tab.canGoForward) {
                    accumulatedX = 0
                    currentAxis = .none
                    tab.cancelSwipeGesture()
                    super.scrollWheel(with: event)
                    return
                }

                let threshold: CGFloat = 55
                let distance = abs(accumulatedX)
                let progress = min(distance / threshold, 1.25)
                let direction: Tab.SwipeDirection = accumulatedX > 0 ? .back : .forward
                let isTriggered = distance >= threshold

                if isTriggered && !hasTriggeredHaptic {
                    hasTriggeredHaptic = true
                    NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)
                } else if !isTriggered && hasTriggeredHaptic {
                    hasTriggeredHaptic = false
                }

                tab.updateSwipeGesture(direction: direction, progress: progress, distance: distance, isTriggered: isTriggered)
                return // Fully consume horizontal event so webpage never moves/wobbles!
            }

        case .horizontalSuppressed:
            // Suppress horizontal elastic overscroll wobble at the edges when cannot go back/forward
            if event.phase == .changed {
                return
            }

        case .vertical:
            // Lock to vertical scrolling: eliminate diagonal horizontal drift (deltaX)
            if (event.phase == .changed || event.momentumPhase == .changed) && abs(deltaX) > 0 {
                if let cgCopy = event.cgEvent?.copy() {
                    cgCopy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                    cgCopy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                    if let filteredEvent = NSEvent(cgEvent: cgCopy) {
                        super.scrollWheel(with: filteredEvent)
                        return
                    }
                }
            }
            super.scrollWheel(with: event)
            return

        case .none:
            // Anti-wobble guard for mid-stream events and momentum phases
            if event.phase == .changed || event.momentumPhase == .changed {
                if abs(deltaY) > abs(deltaX) * 1.2 && abs(deltaX) > 0 {
                    // Predominantly vertical: zero out horizontal drift
                    if let cgCopy = event.cgEvent?.copy() {
                        cgCopy.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: 0)
                        cgCopy.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: 0)
                        if let filteredEvent = NSEvent(cgEvent: cgCopy) {
                            super.scrollWheel(with: filteredEvent)
                            return
                        }
                    }
                } else if abs(deltaX) > abs(deltaY) * 2 && abs(deltaX) > 2 {
                    if (deltaX > 0 && !tab.canGoBack) || (deltaX < 0 && !tab.canGoForward) {
                        return // Suppress page wobble at edge
                    }
                }
            }
            super.scrollWheel(with: event)
        }
    }
}

