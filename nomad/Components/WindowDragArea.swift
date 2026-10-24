//
//  WindowDragArea.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

/// An AppKit view that supports native window dragging and double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragNSView {
        DragNSView()
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {}
}

final class DragNSView: NSView {
    private static var didApplyInitialSize = false

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window = window else { return }
        Lights.keep(window)
        
        if !Self.didApplyInitialSize {
            Self.didApplyInitialSize = true
            window.setContentSize(NSSize(width: 1180, height: 780))
            window.center()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            window?.zoom(nil)
        } else {
            window?.performDrag(with: event)
        }
    }
}
