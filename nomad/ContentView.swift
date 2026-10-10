//
//  ContentView.swift
//  nomad
//
//  Created by tarun on 10/10/26.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var store = BrowserStore()

    var body: some View {
        BrowserView(store: store)
            .ignoresSafeArea()
            .frame(minWidth: 700, minHeight: 450)
    }
}

#Preview {
    ContentView()
}
