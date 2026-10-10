//
//  ContentView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
        }
        .frame(minWidth: 800, minHeight: 500)
    }
}

#Preview {
    ContentView()
}
