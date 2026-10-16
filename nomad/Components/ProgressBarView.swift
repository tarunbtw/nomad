//
//  ProgressBarView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

/// Sleek 2px progress bar that animates across the top bar during page load.
struct ProgressBarView: View {
    @ObservedObject var tab: Tab

    var body: some View {
        GeometryReader { geometry in
            if tab.isLoading && tab.estimatedProgress > 0 && tab.estimatedProgress < 1.0 {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.primary)
                        .frame(width: max(0, geometry.size.width * CGFloat(tab.estimatedProgress)), height: 2)
                        .animation(.linear(duration: 0.15), value: tab.estimatedProgress)
                }
                .transition(.opacity)
            }
        }
        .frame(height: 2)
        .allowsHitTesting(false)
    }
}
