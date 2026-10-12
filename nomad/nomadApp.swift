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
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        NomadAgentServer.shared.stop()
    }
}
