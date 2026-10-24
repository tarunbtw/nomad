//
//  Lights.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import AppKit

/// Positions and vertically centers native macOS window buttons (traffic lights)
/// within the custom top bar strip, providing even margins and balanced layout.
@MainActor
final class Lights: NSObject {
    /// Desired center of the close button (x: 24pt from window left edge, y: 25pt vertically centered in 50pt strip).
    static let centre = CGPoint(x: 24, y: 25)

    private static var kept: [ObjectIdentifier: Lights] = [:]

    static func keep(_ window: NSWindow) {
        guard kept[ObjectIdentifier(window)] == nil else { return }
        kept[ObjectIdentifier(window)] = Lights(window)
    }

    private weak var window: NSWindow?
    private var placing = false
    private let spacing: CGFloat

    private init(_ window: NSWindow) {
        self.window = window
        let row = [NSWindow.ButtonType.closeButton, .miniaturizeButton].compactMap { window.standardWindowButton($0) }
        let measured = row.count == 2 ? row[1].frame.minX - row[0].frame.minX : 0
        spacing = (16...32).contains(measured) ? measured : 20
        super.init()

        let nc = NotificationCenter.default
        for name in [
            NSWindow.didResizeNotification,
            NSWindow.didEndLiveResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didResignKeyNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
            NSWindow.willCloseNotification,
        ] {
            nc.addObserver(self, selector: #selector(place), name: name, object: window)
        }

        let buttons = self.buttons
        if let bar = buttons.first?.superview, let container = bar.superview {
            for view in [container, bar] + buttons {
                view.postsFrameChangedNotifications = true
                nc.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: view)
            }
        }
        place()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
        if let window = window {
            Lights.kept.removeValue(forKey: ObjectIdentifier(window))
        }
    }

    private var buttons: [NSButton] {
        [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].compactMap { window?.standardWindowButton($0) }
    }

    @objc private func place() {
        guard !placing, let window = window, !window.styleMask.contains(.fullScreen) else { return }
        let buttons = self.buttons
        guard buttons.count == 3, let bar = buttons[0].superview, let container = bar.superview else { return }
        placing = true
        defer { placing = false }

        let height: CGFloat = 50
        var frame = container.frame
        if frame.height != height || frame.maxY != window.frame.height || frame.width < 80 {
            frame.size.height = height
            frame.size.width = max(frame.size.width, 80)
            frame.origin.y = window.frame.height - height
            container.frame = frame
        }

        var barFrame = bar.frame
        if barFrame.height != height || barFrame.width < 80 {
            barFrame.size.height = height
            barFrame.size.width = max(barFrame.size.width, 80)
            bar.frame = barFrame
        }

        container.clipsToBounds = false
        bar.clipsToBounds = false

        for (index, button) in buttons.enumerated() {
            button.isHidden = false
            let size = button.frame.size
            let origin = NSPoint(
                x: Lights.centre.x - size.width / 2 + CGFloat(index) * spacing,
                y: bar.bounds.height - Lights.centre.y - size.height / 2
            )
            if button.frame.origin != origin {
                button.setFrameOrigin(origin)
            }
        }
    }
}
