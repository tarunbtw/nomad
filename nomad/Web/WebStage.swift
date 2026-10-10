//
//  WebStage.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import WebKit

/// SwiftUI wrapper for hosting the active tab's WKWebView.
/// Preserves the active WKWebView in memory when tabs switch so no reload is required.
struct WebStage: NSViewRepresentable {
    let tab: Tab?

    func makeNSView(context: Context) -> StageHostView {
        StageHostView()
    }

    func updateNSView(_ hostView: StageHostView, context: Context) {
        hostView.show(tab?.webView)
    }
}

/// AppKit container view that manages the active WKWebView subview.
final class StageHostView: NSView {
    private weak var activeView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    override func layout() {
        super.layout()
        activeView?.frame = bounds
    }

    func show(_ newView: NSView?) {
        guard activeView !== newView else { return }

        // Remove currently displayed web view without destroying it
        activeView?.removeFromSuperview()
        activeView = newView

        // Mount the newly active web view
        if let newView = newView {
            newView.frame = bounds
            newView.autoresizingMask = [.width, .height]
            addSubview(newView)
        }
    }
}
