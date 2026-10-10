//
//  NavigationControls.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Minimal navigation control buttons: Back, Forward, Reload.
struct NavigationControls: View {
    @ObservedObject var tab: Tab

    var body: some View {
        HStack(spacing: 4) {
            Button(action: { tab.goBack() }) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tab.canGoBack)
            .opacity(tab.canGoBack ? 1.0 : 0.35)
            .help("Back (⌘[)")

            Button(action: { tab.goForward() }) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!tab.canGoForward)
            .opacity(tab.canGoForward ? 1.0 : 0.35)
            .help("Forward (⌘])")

            Button(action: {
                if tab.isLoading {
                    tab.stopLoading()
                } else {
                    tab.reload()
                }
            }) {
                Image(systemName: tab.isLoading ? "xmark" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(tab.isLoading ? "Stop Loading" : "Reload (⌘R)")
        }
        .foregroundStyle(.primary)
    }
}
