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
    @ObservedObject var settings: SettingsStore

    var body: some View {
        HStack(spacing: 0) {
            // Traffic lights safe area: window dragging and traffic lights alignment
            WindowDragArea()
                .frame(width: 96, height: 50)

            // Tab Strip (tabs + new tab '+' button) - zero drag layer interference
            TabStripView(store: store)
                .frame(maxWidth: 700, alignment: .leading)

            // Middle empty area: native window dragging and double-click to zoom
            WindowDragArea()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation Controls on the far right end (Back, Forward, Reload)
            if let activeTab = store.activeTab {
                NavigationControls(tab: activeTab)
                    .id(activeTab.id)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: 50)
        .background {
            if settings.isVibrant {
                Color(nsColor: .windowBackgroundColor).opacity(0.35)
            } else {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .overlay(alignment: .bottom) {
            // Non-intrusive progress bar that overlays the bottom edge without adding margins
            if let activeTab = store.activeTab {
                ProgressBarView(tab: activeTab)
            }
        }
    }
}
