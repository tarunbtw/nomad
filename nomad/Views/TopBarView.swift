//
//  TopBarView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Top browser chrome housing traffic lights spacer, navigation buttons, tab strip, and omnibox.
struct TopBarView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            // Allows dragging the macOS window by the top chrome
            WindowDragArea()

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    // Traffic lights safe area (macOS native close/minimize/zoom buttons sit here)
                    Color.clear
                        .frame(width: 76, height: 38)

                    // Navigation Controls (Back, Forward, Reload)
                    if let activeTab = store.activeTab {
                        NavigationControls(tab: activeTab)
                    }

                    // Tab Strip
                    TabStripView(store: store)
                        .frame(maxWidth: 460)

                    // Omnibox / Address Bar
                    if let activeTab = store.activeTab {
                        AddressBarView(store: store, tab: activeTab)
                            .frame(minWidth: 160, maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)

                // Divider line below the top bar
                Divider()
                    .opacity(0.4)
            }
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
