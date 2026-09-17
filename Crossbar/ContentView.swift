//
//  ContentView.swift
//  Crossbar
//
//  Created by Azzaam Chaudhry on 9/16/26.
//

import SwiftUI

struct ContentView: View {
#if DEBUG
    @StateObject private var model = CallProbeModel()

    var body: some View {
        NavigationStack {
            AudioSeamView(probe: model.seamProbe, model: model)
                .padding()
                .navigationTitle("Architecture B Spike")
        }
    }
#else
    var body: some View {
        Text("Crossbar")
    }
#endif
}

#Preview {
    ContentView()
}
