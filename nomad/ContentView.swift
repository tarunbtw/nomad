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
        .background(WindowConfigurator(isVibrant: settings.isVibrant))
        .preferredColorScheme(settings.colorScheme)
        .tint(settings.accentColor)
        .onAppear {
            NomadAgentServer.shared.start(store: store)
        }
        .onDisappear {
            NomadAgentServer.shared.stop()
        }
    }
}

/// Permanently disables automatic window dragging so tabs can be dragged freely without moving the window,
/// and synchronizes window transparency / vibrancy.
private struct WindowConfigurator: NSViewRepresentable {
    let isVibrant: Bool

    func makeNSView(context: Context) -> ConfigNSView {
        let view = ConfigNSView()
        view.isVibrant = isVibrant
        return view
    }

    func updateNSView(_ nsView: ConfigNSView, context: Context) {
        if nsView.isVibrant != isVibrant {
            nsView.isVibrant = isVibrant
        }
    }

    final class ConfigNSView: NSView {
        var isVibrant: Bool = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            guard let window = window else { return }
            window.isMovable = false
            window.isMovableByWindowBackground = false
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            if isVibrant {
                window.isOpaque = false
                window.backgroundColor = .clear
            } else {
                window.isOpaque = true
                window.backgroundColor = .windowBackgroundColor
            }
            window.invalidateShadow()
            SettingsStore.shared.applyTheme()
        }
    }
}

