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
                .frame(width: 80, height: 50)

            // Flexible dynamic tab strip filling space up to navigation controls
            TabStripView(store: store)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Navigation Controls on the far right end (Back, Forward, Reload, Bookmark, Settings)
            if let activeTab = store.activeTab {
                NavigationControls(tab: activeTab, store: store, settings: settings)
                    .padding(.trailing, 14)
            }
        }
        .frame(height: 50)
        .background {
            if settings.isVibrant {
                Color.clear
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
