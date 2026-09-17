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
            VStack(spacing: 16) {
                WebRuntimeView(engine: model.mediaEngine)
                    .frame(maxWidth: .infinity)
                    .frame(height: 360)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 20))

                Text(model.status)
                    .font(.headline)
                    .accessibilityIdentifier("probe.status")

                HStack {
                    Button("Start probe") {
                        model.startOutgoingCall()
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("probe.start")

                    Button("Simulate incoming") {
                        model.simulateIncomingCall()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("probe.incoming")
                }

                Button("Run media only") {
                    model.startMediaOnly()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("probe.mediaOnly")

                HStack {
                    Button(model.isMuted ? "Unmute" : "Mute") {
                        model.toggleMute()
                    }
                    .disabled(!model.hasCall)

                    Button(model.isCameraEnabled ? "Camera off" : "Camera on") {
                        model.toggleCamera()
                    }
                    .disabled(!model.hasCall)

                    Button("Switch camera") {
                        model.switchCamera()
                    }
                    .disabled(!model.hasCall)

                    Button("End", role: .destructive) {
                        model.endCall()
                    }
                    .disabled(!model.hasCall)
                }
                .buttonStyle(.bordered)

                ScrollView {
                    Text(model.mediaEngine.eventLog.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 130)

                Divider()

                Text("Architecture B audio seam")
                    .font(.subheadline.weight(.semibold))

                AudioSeamView(probe: model.seamProbe, model: model)
            }
            .padding()
            .navigationTitle("Architecture A Probe")
            .task {
                model.runLaunchArgumentsIfNeeded()
            }
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
