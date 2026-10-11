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
        let view = StageHostView()
        return view
    }

    func updateNSView(_ hostView: StageHostView, context: Context) {
        hostView.show(tab?.webView)
    }
}

/// AppKit container view that manages the active WKWebView subview with 1:1 pixel fidelity.
final class StageHostView: NSView {
    private weak var activeView: NSView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    override func layout() {
        super.layout()
        if let active = activeView, active.frame != bounds {
            active.frame = bounds
        }
    }

    func show(_ newView: NSView?) {
        guard activeView !== newView else {
            if let active = activeView, active.frame != bounds {
                active.frame = bounds
            }
            return
        }

        // Remove currently displayed web view without destroying it
        activeView?.removeFromSuperview()
        activeView = newView

        // Mount the newly active web view with exact bounds matching
        if let newView = newView {
            if let wv = newView as? WKWebView, wv.magnification != 1.0 {
                wv.setMagnification(1.0, centeredAt: .zero)
            }
            newView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(newView)
            NSLayoutConstraint.activate([
                newView.leadingAnchor.constraint(equalTo: leadingAnchor),
                newView.trailingAnchor.constraint(equalTo: trailingAnchor),
                newView.topAnchor.constraint(equalTo: topAnchor),
                newView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            newView.needsLayout = true
        }
        needsLayout = true
    }
}
