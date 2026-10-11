//
//  TopBarView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Top browser chrome housing traffic lights spacer, tab strip, and trailing navigation controls.
/// Seamlessly blends into the window canvas with zero bottom margin or divider lines.
struct TopBarView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            // Native AppKit layer for dragging and double-click to zoom
            WindowDragArea()

            HStack(spacing: 0) {
                // Traffic lights safe area: leaves even margins on both sides of the window controls
                Color.clear
                    .frame(width: 96, height: 50)

                // Tab Strip (tabs + new tab '+' button)
                TabStripView(store: store)
                    .frame(maxWidth: 700, alignment: .leading)

                // Middle empty area: double-click to zoom across the entire middle
                Spacer()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) {
                        NSApp.keyWindow?.zoom(nil)
                    }

                // Navigation Controls on the far right end (Back, Forward, Reload)
                if let activeTab = store.activeTab {
                    NavigationControls(tab: activeTab)
                        .id(activeTab.id)
                        .padding(.trailing, 14)
                }
            }
            .frame(height: 50)
        }
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .bottom) {
            // Non-intrusive progress bar that overlays the bottom edge without adding margins
            if let activeTab = store.activeTab {
                ProgressBarView(tab: activeTab)
            }
        }
    }
}
