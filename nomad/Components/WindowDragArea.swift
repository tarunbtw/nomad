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
    private var pressed: NSEvent?
    private var moved = false
    private static var didApplyInitialSize = false

    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window = window {
            Lights.keep(window)
            
            // Ensure window opens with the exact 1180x780 default dimensions of the Search app
            if !Self.didApplyInitialSize {
                Self.didApplyInitialSize = true
                window.setContentSize(NSSize(width: 1180, height: 780))
                window.center()
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        pressed = event
        moved = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = window, let pressed = pressed, !moved else { return }
        let dx = event.locationInWindow.x - pressed.locationInWindow.x
        let dy = event.locationInWindow.y - pressed.locationInWindow.y
        if abs(dx) < 3 && abs(dy) < 3 { return }
        moved = true
        window.performDrag(with: pressed)
    }

    override func mouseUp(with event: NSEvent) {
        guard let window = window, !moved, event.clickCount == 2 else { return }
        window.zoom(nil)
    }
}
