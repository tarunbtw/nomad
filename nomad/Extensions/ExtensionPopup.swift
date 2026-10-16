//
//  ExtensionPopup.swift
//  nomad
//
//  Created by tarun on 10/12/26.
//

import AppKit
import WebKit

/// Manages an extension's action popup in a native NSPopover, accurately sized
/// to the page's intrinsic DOM content (Chrome/Blink auto-size algorithm).
///
/// Ensures the popup WKWebView is built from context.webViewConfiguration and registered
/// with the controller via didOpenTab(PopupPage), enabling full background service worker messaging.
@MainActor
final class ExtensionPopup: NSObject, WKUIDelegate, WKNavigationDelegate, NSPopoverDelegate {
    static let shared = ExtensionPopup()

    private var popover: NSPopover?
    private var web: WKWebView?
    private var page: PopupPage?
    private(set) var extensionID: String?
    private weak var button: NSView?
    private var closedByButton: (id: String, at: Date)?

    var view: WKWebView? { web }
    var isUp: Bool { popover?.isShown == true }

    func client(of id: String) -> [String: Any]? {
        guard popover?.isShown == true, extensionID == id, let web, let url = web.url else { return nil }
        return ["id": "popup", "url": url.absoluteString, "visible": true, "focused": popover?.contentViewController?.view.window?.isKeyWindow == true]
    }

    private static var lastSize: [String: NSSize] = [:]
    private var shown = false

    func show(_ url: URL, for context: WKWebExtensionContext, from anchor: NSView?) {
        close()
        guard let configuration = context.webViewConfiguration else { return }

        let initialSize = ExtensionPopup.lastSize[context.uniqueIdentifier] ?? NSSize(width: 360, height: 600)
        let stage = NSView(frame: NSRect(origin: .zero, size: initialSize))
        stage.wantsLayer = true
        stage.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let web = WKWebView(frame: NSRect(origin: .zero, size: initialSize), configuration: configuration)
        web.isInspectable = true
        web.uiDelegate = self
        web.navigationDelegate = self
        web.autoresizingMask = [.width, .height]
        web.underPageBackgroundColor = NSColor.windowBackgroundColor
        web.alphaValue = 1.0
        web.load(URLRequest(url: url))
        stage.addSubview(web)

        let host = NSViewController()
        host.view = stage
        host.preferredContentSize = stage.frame.size

        let popover = NSPopover()
        popover.contentViewController = host
        popover.contentSize = stage.frame.size
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        self.web = web
        self.popover = popover
        self.extensionID = context.uniqueIdentifier
        self.button = anchor

        let page = PopupPage(web: web)
        self.page = page
        ExtensionManager.shared.controller.didOpenTab(page)

        shown = true

        if let anchor, anchor.window != nil {
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        } else if let content = (NSApp.mainWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }))?.contentView {
            let bounds = content.bounds
            let flipped = content.isFlipped
            let spot = NSRect(x: bounds.maxX - 60, y: flipped ? bounds.minY + 40 : bounds.maxY - 40, width: 1, height: 1)
            popover.show(relativeTo: spot, of: content, preferredEdge: flipped ? .maxY : .minY)
        }

        follow()
    }

    private func reveal() {
        guard let web, let stage = popover?.contentViewController?.view else { return }
        web.frame = NSRect(origin: .zero, size: popover?.contentSize ?? stage.bounds.size)
        web.autoresizingMask = [.width, .height]
        web.alphaValue = 1.0
    }

    private func follow() {
        measureAndResize()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.measureAndResize()
        }
    }

    func close() {
        let closing = popover
        forget()
        closing?.performClose(nil)
    }

    private func forget() {
        if let page {
            ExtensionManager.shared.controller.didCloseTab(page, windowIsClosing: false)
        }
        page = nil
        popover = nil
        web = nil
        extensionID = nil
        button = nil
    }

    func closes(_ id: String) -> Bool {
        defer { closedByButton = nil }
        if popover != nil, extensionID == id {
            close()
            return true
        }
        guard let closed = closedByButton, closed.id == id else { return false }
        return Date().timeIntervalSince(closed.at) < 1.5
    }

    // MARK: - DOM Sizing

    @objc(_webView:navigationDidFinishDocumentLoad:)
    func webView(_ webView: WKWebView, navigationDidFinishDocumentLoad navigation: WKNavigation?) {
        guard webView === web else { return }
        measureAndResize()
    }

    private func measureAndResize() {
        guard let web else { return }
        Task { @MainActor [weak self] in
            guard let self, web === self.web else { return }
            let js = """
            (() => {
                const d = document.documentElement;
                if (!d) return null;
                const b = document.body;
                const w = Math.min(800, Math.max(100, Math.ceil(Math.max(d.scrollWidth, d.offsetWidth, b ? b.scrollWidth : 0))));
                const h = Math.min(600, Math.max(50, Math.ceil(Math.max(d.scrollHeight, d.offsetHeight, b ? b.scrollHeight : 0))));
                return [w, h];
            })()
            """
            guard let value = try? await web.evaluateJavaScript(js),
                  let pair = value as? [Double], pair.count == 2 else { return }
            self.apply(NSSize(width: pair[0], height: pair[1]))
        }
    }

    private func apply(_ size: NSSize) {
        guard let popover else { return }
        if abs(size.width - popover.contentSize.width) > 1 || abs(size.height - popover.contentSize.height) > 1 {
            popover.contentViewController?.preferredContentSize = size
            popover.contentSize = size
            popover.contentViewController?.view.setFrameSize(size)
            if shown { web?.frame = NSRect(origin: .zero, size: size) }
        }
        if let id = extensionID { ExtensionPopup.lastSize[id] = size }
        reveal()
    }

    // MARK: - Delegates

    func webViewDidClose(_ webView: WKWebView) { close() }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { follow() }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url {
            ExtensionManager.shared.store?.newTab(url: url, configuration: configuration, select: true)
        }
        close()
        return nil
    }

    func popoverWillClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover, let id = extensionID,
              let button, let window = button.window, let event = NSApp.currentEvent,
              event.window === window, event.type == .leftMouseDown || event.type == .leftMouseUp else { return }
        let spot = button.convert(event.locationInWindow, from: nil)
        if button.bounds.contains(spot) {
            closedByButton = (id, Date())
        }
    }

    func popoverDidClose(_ notification: Notification) {
        guard (notification.object as? NSPopover) === popover else { return }
        forget()
    }
}

/// Represents the popup page as an official tab belonging to the window in WebKit.
@MainActor
final class PopupPage: NSObject, WKWebExtensionTab {
    weak var web: WKWebView?

    init(web: WKWebView) {
        self.web = web
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        ExtensionManager.shared.currentWindow
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        NSNotFound
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        web
    }

    func title(for context: WKWebExtensionContext) -> String? {
        web?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        web?.url
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        !(web?.isLoading ?? false)
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        false
    }

    func close(for context: WKWebExtensionContext) async throws {
        ExtensionPopup.shared.close()
    }
}
