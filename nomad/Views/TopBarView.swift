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
            // Allows dragging the macOS window and double-click to zoom
            WindowDragArea()

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    // Traffic lights safe area: leaves even margins on both sides of the window controls
                    Color.clear
                        .frame(width: 96, height: 50)

                    // Tab Strip (tabs + new tab '+' button)
                    TabStripView(store: store)

                    Spacer(minLength: 20)

                    // Navigation Controls on the far right end (Back, Forward, Reload)
                    if let activeTab = store.activeTab {
                        NavigationControls(tab: activeTab)
                            .id(activeTab.id)
                            .padding(.trailing, 14)
                    }
                }
                .frame(height: 50)

                // Subtle hairline border separating top chrome from web stage
                Divider()
                    .opacity(0.3)
            }
        }
        .frame(height: 50)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
