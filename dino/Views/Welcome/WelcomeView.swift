//
//  WelcomeView.swift
//  dino
//
//  Created for Dino Browser.
//  Quiet, editorial first-launch onboarding over DinoStageScene.
//  Clean typography, essential keyboard shortcuts, optional Arc bookmarks import,
//  and single "Get Started" action.
//

import SwiftUI
import AppKit

struct WelcomeView: View {
    @ObservedObject var settings: SettingsStore
    var store: BrowserStore? = nil
    var onComplete: (() -> Void)? = nil

    @State private var offersArc: Bool = false
    @State private var arcPlan: ArcImportPlan? = nil
    @State private var isImportingArc: Bool = false
    @State private var hasImportedArc: Bool = false

    init(settings: SettingsStore, store: BrowserStore? = nil, onComplete: (() -> Void)? = nil) {
        self.settings = settings
        self.store = store
        self.onComplete = onComplete
    }

    var body: some View {
        ZStack {
            // Calm Dino ambient backdrop
            DinoStageScene(spaceColor: "pine")
                .ignoresSafeArea()

            // Window drag clearance across top edge
            VStack {
                WindowDragArea()
                    .frame(height: 38)
                Spacer()
            }
            .zIndex(10)

            // Centered Editorial Welcome Card
            VStack(spacing: 24) {
                // Editorial Branding & Typography
                VStack(spacing: 8) {
                    if let _ = NSImage(named: "DinoMark") {
                        Image("DinoMark")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 48, height: 48)
                            .shadow(color: Color(hex: 0x023121, opacity: 0.3), radius: 10, y: 4)
                    }

                    Text("Welcome to Dino")
                        .font(.system(size: 38, weight: .semibold, design: .serif))
                        .foregroundStyle(Theme.ink)

                    Text("An ultra-light, native browser built for macOS.")
                        .font(Theme.tabFont)
                        .foregroundStyle(Theme.muted)
                }

                // Frosted Action Card
                let shape = RoundedRectangle(cornerRadius: Theme.panelRadius, style: .continuous)
                VStack(alignment: .leading, spacing: 18) {
                    // Essential Shortcuts Section
                    VStack(alignment: .leading, spacing: 10) {
                        Text("ESSENTIAL SHORTCUTS")
                            .font(.system(size: 10, weight: .semibold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.faint)

                        shortcutRow(keys: "⌘T", label: "Open new tab")
                        shortcutRow(keys: "⌘L", label: "Jump to address bar")
                        shortcutRow(keys: "⌘K", label: "Command bar & search")
                        shortcutRow(keys: "⌥Space", label: "Quick glance peek")
                    }

                    // Arc Import Row (if detected on this Mac)
                    if offersArc, let plan = arcPlan {
                        Divider()
                            .background(Theme.activeTabHairline)

                        HStack(spacing: 12) {
                            Image(systemName: hasImportedArc ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                                .font(.system(size: 18))
                                .foregroundStyle(hasImportedArc ? Theme.frost : Theme.accent)

                            VStack(alignment: .leading, spacing: 2) {
                                Text("Coming from Arc?")
                                    .font(Theme.tabFont)
                                    .foregroundStyle(Theme.ink)
                                Text(hasImportedArc ? "Imported \(plan.spaces.count) spaces into Dino" : "Bring over \(plan.spaces.count) spaces and \(plan.tabCount) tabs in 1 click")
                                    .font(Theme.hintFont)
                                    .foregroundStyle(Theme.muted)
                            }

                            Spacer()

                            if !hasImportedArc {
                                Button(action: importArcSpaces) {
                                    HStack(spacing: 6) {
                                        if isImportingArc {
                                            ProgressView()
                                                .controlSize(.small)
                                        }
                                        Text("Import")
                                            .font(Theme.labelFont)
                                            .foregroundStyle(Theme.ink)
                                    }
                                    .padding(.horizontal, 14)
                                    .frame(height: 28)
                                    .background(Theme.press, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                }
                                .buttonStyle(.plain)
                                .disabled(isImportingArc)
                            }
                        }
                    }

                    Divider()
                        .background(Theme.activeTabHairline)

                    // Get Started Button
                    Button(action: finish) {
                        HStack(spacing: 8) {
                            Text("Start Browsing")
                                .font(Theme.groupHeaderFont)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .foregroundStyle(Color(hex: 0xFFE5CC))
                        .frame(maxWidth: .infinity)
                        .frame(height: 38)
                        .background(Color(hex: 0x023121), in: RoundedRectangle(cornerRadius: Theme.tabRadius, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(22)
                .frame(width: 440)
                .background {
                    CommandBarGlass(shape: shape, color: Theme.page)
                        .clipShape(shape)
                        .shadow(color: Theme.shadowPeek, radius: 24, y: 12)
                        .shadow(color: Theme.shadowPeek.opacity(0.4), radius: 3, y: 1)
                }
            }
            .padding(.top, 24)
        }
        .task {
            await checkForArc()
        }
    }

    @ViewBuilder
    private func shortcutRow(keys: String, label: String) -> some View {
        HStack {
            Text(label)
                .font(Theme.hintFont)
                .foregroundStyle(Theme.ink)

            Spacer()

            Text(keys)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(Theme.muted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.hover, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private func checkForArc() async {
        let stage = await ArcImportService.shared.readArc()
        if case .ready(let plan) = stage {
            self.arcPlan = plan
            self.offersArc = true
        }
    }

    private func importArcSpaces() {
        guard let plan = arcPlan, let store = store else { return }
        isImportingArc = true
        ArcImportService.shared.apply(plan: plan, into: store)
        hasImportedArc = true
        isImportingArc = false
    }

    private func finish() {
        withAnimation(.easeOut(duration: 0.35)) {
            settings.hasCompletedOnboarding = true
            onComplete?()
        }
    }
}
