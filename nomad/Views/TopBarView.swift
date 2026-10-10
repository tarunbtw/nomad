//
//  TopBarView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Top browser chrome housing traffic lights spacer, tab strip, and trailing navigation controls.
struct TopBarView: View {
    @ObservedObject var store: BrowserStore

    var body: some View {
        ZStack {
            // Allows dragging the macOS window by the top chrome
            WindowDragArea()

            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Traffic lights safe area (macOS native close/minimize/zoom buttons sit here)
                    Color.clear
                        .frame(width: 76, height: 38)

                    // Tab Strip (tabs + new tab '+' button)
                    TabStripView(store: store)

                    Spacer(minLength: 20)

                    // Navigation Controls on the far right end (Back, Forward, Reload)
                    if let activeTab = store.activeTab {
                        NavigationControls(tab: activeTab)
                            .id(activeTab.id)
                            .padding(.trailing, 10)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 38)

                // Divider line below the top bar
                Divider()
                    .opacity(0.3)
            }
        }
        .frame(height: 38)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
