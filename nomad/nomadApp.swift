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

    var body: some Scene {
        Window("Nomad", id: "main") {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .printItem) {
                // Replaces standard Page Setup (⇧⌘P) so ⇧⌘P belongs directly to Picture-in-Picture
                Button("Print...") {
                    // Handled inside browser view via ⌘P
                }
                .keyboardShortcut("p", modifiers: .command)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        FloatingVideoManager.shared.land()
        NomadAgentServer.shared.stop()
    }
}
