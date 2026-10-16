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
        if tab?.isFloatingVideo == true {
            if hostView.activeView?.superview === hostView {
                hostView.activeView?.removeFromSuperview()
            }
            hostView.activeView = nil
            return
        }
        hostView.show(tab?.webView)
    }
}

/// AppKit container view that manages the active WKWebView subview with 1:1 pixel fidelity.
final class StageHostView: NSView {
    var activeView: NSView?

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

    func show(_ newView: NSView?) {
        guard activeView !== newView else { return }

        // Remove currently displayed web view without destroying it, only if it is actually our subview
        if let current = activeView, current.superview === self {
            current.removeFromSuperview()
        }
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
