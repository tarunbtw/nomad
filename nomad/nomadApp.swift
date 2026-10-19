//
//  nomadApp.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

@main
struct nomadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    init() {
        if CommandLine.arguments.contains("--mcp") || CommandLine.arguments.contains("mcp") {
            NomadMCPServer.run()
            exit(0)
        }
    }

    var body: some Scene {
        Window("Nomad", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates...") {
                    Updater.shared.checkByHand()
                }
            }
            CommandGroup(replacing: .printItem) {
                // Replaces standard Page Setup (⇧⌘P) so ⇧⌘P belongs directly to Picture-in-Picture
                Button("Print...") {
                    // Handled inside browser view via ⌘P
                }
                .keyboardShortcut("p", modifiers: .command)
            }
            CommandGroup(after: .newItem) {
                Button("Bring Things Over...") {
                    SettingsStore.shared.promptBringThingsOver()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Updater.shared.checkIfDue()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FloatingVideoManager.shared.land()
        NomadAgentServer.shared.stop()
    }
}
