//
//  OnboardingView.swift
//  nomad
//
//  Created by tarun on 16/10/26.
//

import SwiftUI
import AppKit

/// A lightweight, single-screen welcome experience shown on first launch.
/// Fast, uncluttered, and built natively for macOS with Swift and WebKit.
struct OnboardingView: View {
    @ObservedObject var settings: SettingsStore
    var onStart: (() -> Void)? = nil

    @State private var appearStage: Int = 0
    @State private var isHoveringButton: Bool = false

    var body: some View {
        ZStack(alignment: .top) {
            // Background Canvas (supports vibrant translucency or solid window background)
            Group {
                if settings.isVibrant {
                    VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                } else {
                    Color(nsColor: .windowBackgroundColor)
                }
            }
            .ignoresSafeArea()

            VStack(spacing: 0) {
                // Top drag region preserving native window dragging & traffic lights alignment
                HStack {
                    WindowDragArea()
                        .frame(maxWidth: .infinity, maxHeight: 50)
                }
                .frame(height: 50)

                Spacer()

                // Centered Editorial Content
                VStack(spacing: 28) {
                    // Stage 1: Hand-Drawn Nomad Mark (Clean, transparent brand mark)
                    Group {
                        if let _ = NSImage(named: "NomadMark") {
                            Image("NomadMark")
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: 96, height: 96)
                        } else {
                            // Fallback glyph if image asset is unavailable
                            Image(systemName: "safari")
                                .font(.system(size: 52, weight: .light))
                                .foregroundStyle(settings.accentColor)
                                .frame(width: 96, height: 96)
                        }
                    }
                    .opacity(appearStage >= 1 ? 1 : 0)
                    .offset(y: appearStage >= 1 ? 0 : 10)

                    // Stage 2: Title & Subtitle
                    VStack(spacing: 6) {
                        Text("Nomad")
                            .font(.system(size: 28, weight: .medium, design: .default))
                            .foregroundStyle(.primary)
                            .tracking(0.3)

                        Text("A fast, lightweight and agentic browser for macOS")
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(.secondary)
                    }
                    .opacity(appearStage >= 2 ? 1 : 0)
                    .offset(y: appearStage >= 2 ? 0 : 10)

                    // Stage 3: Ethos & Core Principles
                    VStack(spacing: 6) {
                        Text("Built with Swift and WebKit.")
                        Text("Bare,fast and zero telemetry.")
                    }
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.secondary.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .padding(.horizontal, 32)
                    .opacity(appearStage >= 3 ? 1 : 0)
                    .offset(y: appearStage >= 3 ? 0 : 10)

                    // Stage 4: "Start using Nomad" Action Button
                    Button(action: completeOnboarding) {
                        HStack(spacing: 8) {
                            Text("Start using Nomad")
                                .font(.system(size: 13, weight: .medium))
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color(nsColor: .windowBackgroundColor))
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(isHoveringButton ? 0.88 : 1.0))
                        )
                        .scaleEffect(isHoveringButton ? 1.02 : 1.0)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction) // Triggers on Enter/Return key
                    .onHover { hovering in
                        withAnimation(.easeInOut(duration: 0.15)) {
                            isHoveringButton = hovering
                        }
                    }
                    .padding(.top, 8)
                    .opacity(appearStage >= 4 ? 1 : 0)
                    .offset(y: appearStage >= 4 ? 0 : 10)
                }
                .frame(maxWidth: 480)

                Spacer()

                // Subtle bottom shortcut hint
                Text("Press ↵ Return to begin")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 24)
                    .opacity(appearStage >= 4 ? 0.7 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            startStaggeredAnimation()
        }
    }

    private func startStaggeredAnimation() {
        // Stage 1: Mark
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appearStage = 1
            }
        }
        // Stage 2: Title
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appearStage = 2
            }
        }
        // Stage 3: Body
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appearStage = 3
            }
        }
        // Stage 4: Button
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
            withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                appearStage = 4
            }
        }
    }

    private func completeOnboarding() {
        withAnimation(.easeInOut(duration: 0.32)) {
            settings.hasCompletedOnboarding = true
            onStart?()
        }
    }
}
