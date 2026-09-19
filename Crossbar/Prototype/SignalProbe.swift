#if DEBUG
import Combine
import Foundation
import SwiftUI
import WebRTC

/// The signalling instrument: joins a room directly and reports what the protocol
/// does, with no Family Call control plane involved. Kept because it is how the wire
/// contract gets re-measured without ringing anyone.
struct SignalProbeSection: View {
    @StateObject private var media = CallMediaSource()
    @StateObject private var peerA = MiroTalkSignalClient(label: "A")
    @StateObject private var peerB = MiroTalkSignalClient(label: "B")
    @StateObject private var peerC = MiroTalkSignalClient(label: "C")
    @State private var expanded = false
    @State private var room = "crosstest"
    @State private var ignoreStun = false
    @State private var viaNode = false

    var body: some View {
        DisclosureGroup("MiroTalk signalling (native Socket.IO)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Do not run the seam capture at the same time — the camera is shared.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("room id", text: $room)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.caption2.monospaced())

                Toggle("Ignore server iceServers (STUN off)", isOn: $ignoreStun)
                    .font(.caption2)
                    .accessibilityIdentifier("signal.ignorestun")

                Toggle("Route signalling through the embedded node", isOn: $viaNode)
                    .font(.caption2)
                    .accessibilityIdentifier("signal.vianode")

                HStack {
                    Button("A join") { join(peerA) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.a.join")
                    Button("B join") { join(peerB) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.b.join")
                    Button("C join") { join(peerC) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.c.join")
                    Button("Disconnect") { disconnectAll() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.disconnect")
                }

                Text("A: \(peerA.state)   B: \(peerB.state)   C: \(peerC.state)")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                videoGrid

                log(peerA.lines)
                log(peerB.lines)
                log(peerC.lines)
            }
            .padding(.top, 4)
        }
        .font(.caption)
        // Same reason as the Family Call gate: the buttons on this screen cannot be
        // pressed from here, because the MCP device-interaction tools only offer
        // simulators, so a verification run needs an automatic path.
        //   xcrun devicectl device process launch … -e '{"CROSSBAR_SIGNAL_AUTOROOM":"room"}'
        //
        // Two peers, not one: joining only A proves nothing about rendering, because
        // there is no remote track to draw. A and B in one room connect to each other,
        // so each receives and decodes the other's video — which exercises the
        // receive path with no external peer and no browser needed.
        .task {
            let auto = ProcessInfo.processInfo.environment["CROSSBAR_SIGNAL_AUTOROOM"] ?? ""
            guard !auto.isEmpty else { return }
            // How many of A/B/C join. One is right when an external peer is the thing
            // under test, because a second native peer would compete for the same
            // remote-track slot and make the tile ambiguous.
            let count = Int(ProcessInfo.processInfo.environment["CROSSBAR_SIGNAL_AUTOPEERS"] ?? "1") ?? 1
            expanded = true
            // The carrier is gated the same way as the room, and for the same reason:
            // the run that matters is the one nobody can start by hand.
            //   … -e '{"CROSSBAR_SIGNAL_AUTOROOM":"room","CROSSBAR_SIGNAL_VIANODE":"1"}'
            if ProcessInfo.processInfo.environment["CROSSBAR_SIGNAL_VIANODE"] == "1" {
                viaNode = true
            }
            // The node's own counters, read while the call is up.
            //
            // The system Tailscale app is also installed on this phone, so a working
            // socket says a route worked, not which one — and the node's counters only
            // move for what the node carried itself. Sampled here rather than in the
            // node-routed branch alone because a run with the socket dialled directly
            // is the control: these stay flat there, which is what makes their growth
            // in a routed run attributable to the node.
            Task {
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    await TailscaleProbe.shared.logNodeTraffic("during call")
                }
            }
            // The field is updated so it does not name a room other than the one
            // joined; the override is still passed explicitly because that is what
            // the connect actually uses.
            room = auto
            join(peerA, roomOverride: auto)
            if count >= 2 { join(peerB, roomOverride: auto) }
            if count >= 3 { join(peerC, roomOverride: auto) }
        }
    }

    /// Local capture beside each peer's decoded video.
    ///
    /// Each client here holds one remote peer, so `.values.first` names the right
    /// track; the multiframe case is the product flow's, which keys properly. What
    /// this renders is *decoded* frames — absent, not merely unproven, until media
    /// actually arrives, which is why a black tile is meaningful and a frozen one is
    /// not.
    private var videoGrid: some View {
        HStack(spacing: 6) {
            tile(media.videoTrack, "local")
            tile(peerA.remoteVideo.values.first, "A")
            tile(peerB.remoteVideo.values.first, "B")
            tile(peerC.remoteVideo.values.first, "C")
        }
    }

    private func tile(_ track: RTCVideoTrack?, _ caption: String) -> some View {
        VideoTile(track: track, caption: caption)
            .frame(height: 96)
    }

    private func join(_ client: MiroTalkSignalClient, roomOverride: String? = nil) {
        let room = roomOverride ?? self.room
        client.media = media
        client.ignoreServerIceServers = ignoreStun
        media.startCapture()
        // Audio is gated until something opens it, and CallKit is not in this path —
        // without this the probe joins a call that records and plays nothing, which is
        // also why the process had no claim on background execution.
        client.record(media.enableAudio())
        guard viaNode else {
            client.connect(room: room)
            return
        }
        Task {
            do {
                let session = try await TailscaleProbe.shared.proxiedSession()
                // Read the node's counters before anything is dialled, so the growth
                // during the call is attributable to the call.
                await TailscaleProbe.shared.logNodeTraffic("before connecting")
                client.transport = .init(configuration: session.configuration,
                                         label: "embedded node \(session.loopbackAddress)")
                client.connect(room: room)
            } catch {
                // Deliberately not falling back to the direct route. A call that took
                // the system's path while the screen says "via node" would look like
                // the measurement succeeded, which is the failure mode this project
                // has already paid for twice.
                client.record("not joining — no node-carried transport: \(error.localizedDescription)")
            }
        }
    }

    private func disconnectAll() {
        peerA.disconnect()
        peerB.disconnect()
        peerC.disconnect()
        media.stopCapture()
    }

    private func log(_ lines: [String]) -> some View {
        Text(lines.suffix(10).joined(separator: "\n"))
            .font(.caption2.monospaced())
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }
}
#endif
