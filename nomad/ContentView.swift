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
    @StateObject private var settings = SettingsStore.shared

    var body: some View {
        ZStack {
            BrowserView(store: store)
                .ignoresSafeArea()

            if !settings.hasCompletedOnboarding {
                OnboardingView(settings: settings)
                    .transition(.opacity.combined(with: .scale(scale: 1.01)))
                    .zIndex(500)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(WindowConfigurator())
        .preferredColorScheme(settings.colorScheme)
        .onAppear {
            NomadAgentServer.shared.start(store: store)
        }
        .onDisappear {
            NomadAgentServer.shared.stop()
        }
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
            SettingsStore.shared.applyTheme()
        }
    }
}

