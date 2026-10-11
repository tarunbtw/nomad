//
//  ContentView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI
import AppKit

struct ContentView: View {
    @StateObject private var store = BrowserStore()

    var body: some View {
        BrowserView(store: store)
            .ignoresSafeArea()
            .frame(minWidth: 640, minHeight: 420)
            .background(WindowConfigurator())
    }
}

/// Permanently disables automatic window dragging so tabs can be dragged freely without moving the window.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfigNSView {
        ConfigNSView()
    }

    func updateNSView(_ nsView: ConfigNSView, context: Context) {}

    final class ConfigNSView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window = window else { return }
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}

#Preview {
    ContentView()
}
