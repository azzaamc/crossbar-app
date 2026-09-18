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
        VStack(spacing: 2) {
            RTCVideoSurface(track: track)
                .frame(height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private func join(_ client: MiroTalkSignalClient, roomOverride: String? = nil) {
        client.media = media
        client.ignoreServerIceServers = ignoreStun
        media.startCapture()
        client.connect(room: roomOverride ?? room)
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
