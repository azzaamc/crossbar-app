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
    @Environment(\.scenePhase) private var scenePhase
    @State private var pip = CallPiPController()
    @State private var pipBox = ViewBox()

    /// Holds the tile's view across view updates.
    ///
    /// A class rather than `@State`: the view is handed over from inside
    /// `makeUIView`, which runs during a SwiftUI update, and mutating state there is not
    /// allowed — the change can be dropped without complaint, which is exactly how the
    /// first attempt at this armed no window at all.
    @MainActor final class ViewBox {
        var view: RTCMTLVideoView?
    }

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
            // PiP's outcome is only visible in the client's log, and a window that never
            // appeared is indistinguishable from one never asked for.
            pip.onLog = { [peerA] line in peerA.record("PiP: \(line)") }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background:
                // A video call that goes to Picture-in-Picture keeps its camera — that is
                // what every other calling app does, and it is possible now that the
                // capture session has opted into multitasking access. Only a call with no
                // PiP window falls back to audio: there the camera is taken by iOS
                // anyway, and the far end is told rather than left with a frozen frame.
                if pip.isArmed {
                    peerA.record("left the app — video call in PiP, camera stays")
                } else {
                    for client in [peerA, peerB, peerC] where client.myPeerId.isEmpty == false {
                        client.setVideoEnabled(false)
                    }
                    peerA.record("left the app — no PiP, so audio only")
                }
            case .active:
                for client in [peerA, peerB, peerC] where client.myPeerId.isEmpty == false {
                    client.setVideoEnabled(true)
                }
                // Whether it *was* active: `stopPictureInPicture()` is asynchronous, so
                // reading the flag after asking would report `true` for a window that is
                // already going away — the same kind of lie as a state label that
                // describes the request rather than the outcome.
                let wasActive = pip.isActive
                pip.closeWindow()
                peerA.record("returned to the app — PiP was active=\(wasActive)")
            default:
                break
            }
        }
        // The remote track and the tile's view arrive in either order, and neither moment
        // is guaranteed to be after the other — so this both waits and reacts. Nothing here
        // touches SwiftUI state (the tile's view lives in a class box precisely because the
        // view update may not be mutated), so it is safe from either side.
        .onChange(of: peerA.remoteVideo.count) { _, _ in armPiPIfPossible() }
        .task {
            for _ in 0..<180 {
                if pip.isArmed { break }
                armPiPIfPossible()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            if !pip.isArmed {
                peerA.record("PiP was never armed: remoteVideo=\(peerA.remoteVideo.count) tileView=\(pipBox.view != nil) supported=\(pip.isSupported)")
            }
        }
    }

    /// Arms Picture-in-Picture once there is both a remote picture and a tile to grow out
    /// of. Harmless to call repeatedly.
    private func armPiPIfPossible() {
        guard !pip.isArmed,
              let track = peerA.remoteVideo.values.first,
              let view = pipBox.view
        else { return }
        // Before arming, because this is a property of the capture session and PiP is what
        // needs it: without it, minimising a video call takes the camera away.
        peerA.record(media.enableMultitaskingCamera())
        pip.arm(track: track, sourceView: view)
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
            tile(peerA.remoteVideo.values.first, "A", cameraOff: cameraOff(peerA), onViewReady: { view in
                // Kept because PiP has to animate out of the tile the user is watching.
                // Arming happens elsewhere: this runs during a SwiftUI update.
                pipBox.view = view
            })
            tile(peerB.remoteVideo.values.first, "B", cameraOff: cameraOff(peerB))
            tile(peerC.remoteVideo.values.first, "C", cameraOff: cameraOff(peerC))
        }
    }

    /// Whether this client's one remote peer has said its camera is off.
    ///
    /// The tile then says so rather than drawing the last frame it received, which is
    /// indistinguishable from a working call.
    private func cameraOff(_ client: MiroTalkSignalClient) -> Bool {
        guard let peerID = client.remoteVideo.keys.first else { return false }
        return client.remoteVideoOff.contains(peerID)
    }

    private func tile(
        _ track: RTCVideoTrack?,
        _ caption: String,
        cameraOff: Bool = false,
        onViewReady: ((RTCMTLVideoView) -> Void)? = nil
    ) -> some View {
        VideoTile(track: track, caption: caption, cameraOff: cameraOff, onViewReady: onViewReady)
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
                let transport = try await TailnetNode.shared.attach()
                // Read the node's counters before anything is dialled, so the growth
                // during the call is attributable to the call.
                await TailscaleProbe.shared.logNodeTraffic("before connecting")
                client.transport = transport
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
        pip.disarm()
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
