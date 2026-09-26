import Combine
import Foundation
import WebRTC

/// A native Engine.IO v4 / Socket.IO v5 client plus peer connections, reduced to
/// the subset the audited MiroTalk contract requires.
///
/// `docs/MIROTALK_CORE_AUDIT.md` determines what is sent and in what shape. Two
/// parts of it had never been executed from native code and are what this
/// instrument now tests:
///
/// 1. **Admission** — connect, handshake, `join`. Verified 2026-09-17.
/// 2. **The offer trigger.** MiroTalk delegates this entirely to the browser's
///    `negotiationneeded` event, which Objective-C libwebrtc does not expose. The
///    audit calls this the one undetermined part and says it can only be validated
///    against a live 1.9.64 peer. The policy synthesised here is deliberately
///    explicit and logged as such: append tracks, then offer once, because the
///    server said `should_create_offer`.
///
/// Wire format, for reference:
///   Engine.IO v4 over WebSocket: `0` open, `1` close, `2` ping, `3` pong, `4` message
///   Socket.IO v5 inside a `4` message: `0` connect, `2` event, `4` connect_error
///   so `40` is an Engine.IO message carrying a Socket.IO connect, and
///   `42["join",{...}]` is an event.
@MainActor
final class MiroTalkSignalClient: NSObject, ObservableObject {
    @Published private(set) var state = "idle"

    /// Whether the socket is still open.
    ///
    /// Asked of the task rather than inferred from `state`, which is prose written for a
    /// person ("joined (no peers)", "in a call") and too loose to branch on. What branches
    /// on it is the recovery path after the node is rebuilt: a socket holding a
    /// now-stale loopback has to be re-dialled, and one that is still open must not be.
    var isSocketOpen: Bool { task?.state == .running }
    @Published private(set) var lines: [String] = []

    /// Distinguishes the two probe peers in the log and to the server.
    let label: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var logHandle: FileHandle?
    private var roomId = ""
    private let peerUUID = UUID().uuidString

    /// One camera and microphone shared by every peer connection, which is how the
    /// product must work: a single capture, many senders. An earlier revision gave
    /// each client its own capturer and they fought over the capture session — both
    /// peers reported "media prepared (audio + Front Camera)" while only audio was
    /// verifiably flowing.
    var media: CallMediaSource?

    /// When set, the server-supplied `iceServers` are discarded and ICE runs on host
    /// candidates alone. This is the decision under test, not a preference: with the
    /// public STUN path demonstrably carrying an off-LAN call, the only way to learn
    /// whether the Tailscale host candidates could have carried it instead is to
    /// remove STUN and see.
    var ignoreServerIceServers = false

    // Peer connections, keyed by remote Socket.IO id, as the audited contract does.
    private var peers: [String: RTCPeerConnection] = [:]
    private var pendingCandidates: [String: [RTCIceCandidate]] = [:]

    /// Remote video tracks, keyed by peer, for rendering.
    ///
    /// Published because a surface has to rebind when a track arrives. Keyed off
    /// receivers rather than streams: under Unified Plan the track is available from
    /// the receiver before any media flows, so the view attaches early and shows
    /// nothing until frames actually arrive — which is the honest state, and the
    /// surface cannot be relied on to prove liveness anyway.
    @Published private(set) var remoteVideo: [String: RTCVideoTrack] = [:]

    /// Remote display names by peer, as the server reports them in `addPeer`.
    ///
    /// Carried because a tile captioned with a six-character socket id does not say who
    /// is on the call, and the name is already arriving on the wire.
    @Published private(set) var remoteNames: [String: String] = [:]

    /// Peers whose camera is off, from their `peerStatus`.
    ///
    /// Needed because a peer that stops sending video leaves its last frame drawn on
    /// this device — the surface keeps it — so "camera off" and "call broken" look
    /// identical without this. MiroTalk's own client hides the peer's video element and
    /// shows the avatar on the same message; this is the same fact, kept where a tile
    /// can read it.
    @Published private(set) var remoteVideoOff: Set<String> = []

    /// This client's own Socket.IO id, which is the `peer_id` the room knows it by.
    ///
    /// Needed for `peerStatus`, whose payload names the peer making the claim. Taken
    /// from the namespace connect frame, which is the only place the server says it.
    private(set) var myPeerId = ""

    private var statsTimer: Timer?
    private var inboundBytes: [String: [String: Int]] = [:]
    private var outboundBytes: [String: [String: Int]] = [:]
    private var reportedPath: [String: String] = [:]
    private var reportedTailnetPairs: Set<String> = []

    /// Where the signalling socket is created, which is where the route is chosen.
    ///
    /// Set by `CallSession` to the embedded node's carrier before the socket is dialled,
    /// so the signalling socket and the control plane leave by the same route and neither
    /// needs the Tailscale app installed. `CallTransport` documents what each route means,
    /// and why the label travels with the configuration rather than beside it.
    var transport = CallTransport()

    /// The MiroTalk origin.
    ///
    /// The product flow supplies this from the `joinUrl` the backend returns, so the
    /// host is never a second constant that could drift from the one the backend
    /// actually used. The environment override remains for the standalone instrument,
    /// which has no `joinUrl` to read.
    var originOverride: URL?

    /// Who this peer appears as to the rest of the room.
    ///
    /// The standalone instrument labels itself `Crossbar A/B/C` because it is not an
    /// authenticated client. The product flow sets the enrolled person's display name,
    /// which is what everyone else in the call actually sees.
    var peerName: String?

    private var origin: URL {
        originOverride
            ?? ProcessInfo.processInfo.environment["CROSSBAR_MIROTALK_ORIGIN"]
                .flatMap(URL.init(string:))
            ?? URL(string: "https://qatar-vpn.tailea67b0.ts.net")!
    }

    init(label: String) {
        self.label = label
        super.init()
    }

    // MARK: - Connection

    func connect(room: String) {
        disconnect()
        let room = room.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !room.isEmpty else { return }
        roomId = room

        var components = URLComponents(url: origin, resolvingAgainstBaseURL: false)!
        components.scheme = origin.scheme == "https" ? "wss" : "ws"
        components.path = "/socket.io/"
        var query = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        // The same session the control plane presents, when this device has one: the
        // signalling host is the service's, so a service that asks devices to identify
        // themselves asks here too. Absent for a device that was never enrolled, which
        // leaves this URL exactly as it was built before device identity existed.
        if let token = DeviceAuth.shared.sessionToken {
            query.append(URLQueryItem(name: "token", value: token))
        }
        components.queryItems = query
        guard let url = components.url else {
            append("could not build socket.io URL from \(origin.absoluteString)")
            return
        }

        state = "connecting"
        append("peer \(label) room=\(room) uuid=\(peerUUID.prefix(8))")
        append("connecting \(url.absoluteString) via \(transport.label)")

        let session = transport.session()
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        receiveLoop(task)
    }

    /// A line the caller wants in this client's evidence log.
    ///
    /// The transport decision is made by the caller, so the reason a connection was
    /// not made belongs in the same file as the negotiation it did not have.
    func record(_ line: String) {
        append(line)
    }

    func disconnect() {
        statsTimer?.invalidate()
        statsTimer = nil
        for (_, pc) in peers { pc.close() }
        peers.removeAll()
        pendingCandidates.removeAll()
        inboundBytes.removeAll()
        outboundBytes.removeAll()
        remoteVideo.removeAll()
        remoteNames.removeAll()

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = "disconnected"
        // The room's identifiers name things inside a room, and there is no room now. Left
        // behind, `myPeerId` answers "am I in a call?" with a stale yes — which is how a
        // camera came back on after a call had ended, the next time the app came forward.
        myPeerId = ""
        roomId = ""
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let message):
                    switch message {
                    case .string(let text): self.handleFrame(text)
                    case .data(let data): self.handleFrame(String(decoding: data, as: UTF8.self))
                    @unknown default: break
                    }
                    self.receiveLoop(task)
                case .failure(let error):
                    self.state = "closed"
                    self.append("receive failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func send(_ packet: String) {
        task?.send(.string(packet)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.append("send failed: \(error.localizedDescription)") }
        }
    }

    private func emit(_ event: String, _ payload: [String: Any]) {
        guard
            let data = try? JSONSerialization.data(withJSONObject: [event, payload]),
            let json = String(data: data, encoding: .utf8)
        else {
            append("could not encode \(event)")
            return
        }
        send("42\(json)")
    }

    // MARK: - Framing

    private func handleFrame(_ text: String) {
        // Engine.IO v4 separates a multi-packet payload with U+001E. A WebSocket
        // frame normally holds one packet, but splitting costs nothing.
        for packet in text.split(separator: "\u{1e}") {
            handleEnginePacket(String(packet))
        }
    }

    private func handleEnginePacket(_ packet: String) {
        guard let type = packet.first else { return }
        let body = String(packet.dropFirst())
        switch type {
        case "0":
            append("engine.io open \(body)")
            state = "handshaken"
            send("40") // connect to the default namespace
        case "1":
            append("engine.io close")
            state = "closed"
        case "2":
            // Logged because liveness across a test window is otherwise invisible:
            // a socket the server has dropped and a socket that simply received
            // nothing look identical in every other line.
            append("engine.io ping -> pong")
            send("3")
        case "3":
            break
        case "4":
            handleSocketPacket(body)
        default:
            append("engine.io \(type) \(body.prefix(200))")
        }
    }

    private func handleSocketPacket(_ body: String) {
        guard let type = body.first else { return }
        let rest = String(body.dropFirst())
        switch type {
        case "0":
            append("socket.io connected \(rest)")
            // `rest` is the namespace connect payload; its sid is how the room names
            // this peer, and `peerStatus` has to name it.
            if let data = rest.data(using: .utf8),
               let shape = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let sid = shape["sid"] as? String {
                myPeerId = sid
            }
            state = "joined-namespace"
            emitJoin()
        case "2":
            handleEvent(rest)
        case "4":
            append("connect_error \(rest)")
            state = "rejected"
        case "3":
            append("ack \(rest.prefix(200))")
        default:
            append("socket.io \(type) \(rest.prefix(300))")
        }
    }

    private func handleEvent(_ payload: String) {
        guard
            let data = payload.data(using: .utf8),
            let array = try? JSONSerialization.jsonObject(with: data) as? [Any],
            let name = array.first as? String
        else {
            append("unparseable event \(payload.prefix(120))")
            return
        }
        let argument = array.count > 1 ? array[1] as? [String: Any] : nil

        // Screens get a prefix, the file gets the whole payload: an SDP is far too
        // long to read on screen and the file is what actually gets pulled.
        append("event \(name) \(payload.prefix(100))", detail: "event \(name) \(payload)")

        switch name {
        case "addPeer": if let argument { handleAddPeer(argument) }
        case "sessionDescription": if let argument { handleSessionDescription(argument) }
        case "iceCandidate": if let argument { handleIceCandidate(argument) }
        case "peerStatus": if let argument { handlePeerStatus(argument) }
        case "removePeer": if let argument, let id = argument["peer_id"] as? String { removePeer(id) }
        default: break
        }
    }

    // MARK: - Media
    // Local media now lives in CallMediaSource and is shared by every peer.

    // MARK: - Join

    /// The payload shape is taken from the audited contract
    /// (`docs/MIROTALK_CORE_AUDIT.md`, "join payload"). `peer_name` is the enrolled
    /// person's display name in the product flow; the instrument falls back to its own
    /// label because it is not an authenticated client.
    private func emitJoin() {
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        let payload: [String: Any] = [
            "join_data_time": ISO8601DateFormatter().string(from: Date()),
            "channel": roomId,
            "channel_password": NSNull(),
            "peer_info": [
                "osName": "iOS",
                "osVersion": version,
                "browserName": "Crossbar Native Probe",
                "browserVersion": "1",
                "extras": [:],
            ],
            "peer_uuid": peerUUID,
            "peer_name": peerName ?? "Crossbar \(label)",
            "peer_avatar": "",
            "peer_token": NSNull(),
            // Whether this device is sending video, read from the track rather than hard-set:
            // `CallSession` keeps that flag in step with the call's kind *and* with the camera
            // button, so this is the one expression the two cannot disagree about. It matters
            // to the far end — a room told `peer_video_status: true` by an audio call draws a
            // black rectangle and waits for frames that are never sent, which is the same
            // confusion the camera path was built to avoid, and being told `false` is what
            // makes MiroTalk's own client draw an avatar instead.
            //
            // `peer_video` stays true for both kinds of call, and deliberately. The connection
            // does carry video — the m-lines are identical, because the track exists from
            // `CallMediaSource.init` rather than from capture — so what changes is the camera,
            // and a peer that turns video on mid-call announces that with `peerStatus` against
            // this same room. `false` here would be claiming the call cannot do what it can.
            "peer_video": true,
            "peer_audio": true,
            "peer_video_status": media?.videoTrack.isEnabled ?? false,
            "peer_audio_status": true,
            "peer_screen_status": false,
            "peer_hand_status": false,
            "peer_rec_status": false,
            "peer_privacy_status": false,
            "userAgent": "Crossbar/1.0 (iOS)",
        ]
        append("emit join channel=\(roomId)")
        emit("join", payload)
        state = "join sent — awaiting addPeer/serverInfo"
    }

    // MARK: - Camera status

    /// Tells the room whether this peer's camera is on, and starts or stops the camera.
    ///
    /// The wire shape is MiroTalk's, read from the deployed client rather than guessed:
    /// `emitPeerStatus('video', myVideoStatus)` sends `peerStatus` with
    /// `{room_id, peer_name, peer_id, element: "video", status, extras}`, and the receive
    /// side hides that peer's video element and shows their avatar. It matters here
    /// because a peer that stops sending leaves its last frame drawn on the other device
    /// — so without this, "camera off" and "call broken" look identical to the far end.
    ///
    /// No renegotiation is involved, which is also true of MiroTalk's own camera path.
    @discardableResult
    func setVideoEnabled(_ enabled: Bool) -> String {
        guard !myPeerId.isEmpty else { return "camera not signalled: not in a room yet" }

        if enabled {
            media?.startCapture()
        } else {
            media?.stopCapture()
        }
        emit("peerStatus", [
            "room_id": roomId,
            "peer_name": peerName ?? "Crossbar \(label)",
            "peer_id": myPeerId,
            "element": "video",
            "status": enabled,
            "extras": [String: Any](),
        ])
        let line = "camera \(enabled ? "back on" : "off") — peerStatus video=\(enabled)"
        append(line)
        return line
    }

    /// The far end's camera status, which tiles read to stop drawing a stale frame.
    private func handlePeerStatus(_ payload: [String: Any]) {
        guard
            let peerId = payload["peer_id"] as? String,
            let element = payload["element"] as? String,
            let status = payload["status"] as? Bool,
            element == "video"
        else { return }

        if status {
            remoteVideoOff.remove(peerId)
        } else {
            remoteVideoOff.insert(peerId)
        }
        append("peerStatus \(peerId.prefix(8)) video=\(status ? "on" : "off")")
    }

    // MARK: - Peering

    private func handleAddPeer(_ payload: [String: Any]) {
        guard
            let peerId = payload["peer_id"] as? String,
            let factory = media?.factory
        else {
            append("addPeer ignored — no local media source")
            return
        }
        // The audited contract dedupes against existing connections.
        guard peers[peerId] == nil else {
            append("addPeer \(peerId.prefix(8)) ignored (already connected)")
            return
        }
        let shouldOffer = payload["should_create_offer"] as? Bool ?? false
        if let name = payload["peer_name"] as? String { remoteNames[peerId] = name }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        let serverIceServers = Self.iceServers(from: payload["iceServers"])
        config.iceServers = ignoreServerIceServers ? [] : serverIceServers
        append("iceServers: server=\(serverIceServers.count) applied=\(config.iceServers.count)\(ignoreServerIceServers ? " (STUN IGNORED)" : "")")
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = factory.peerConnection(with: config, constraints: constraints, delegate: self) else {
            append("could not create a peer connection for \(peerId.prefix(8))")
            return
        }
        peers[peerId] = pc

        append("addPeer \(peerId.prefix(8)) should_create_offer=\(shouldOffer) iceServers=\(config.iceServers.count)")

        // Offer trigger, synthesised. MiroTalk arms `negotiationneeded` and lets the
        // browser decide when to fire; libwebrtc has no such event, so tracks are
        // appended first and the offer follows deliberately. This ordering is the
        // audited invariant: the offer must be made after tracks exist, or an
        // offerer with nothing to send produces no usable m-lines.
        if let audioTrack = media?.audioTrack { _ = pc.add(audioTrack, streamIds: ["crossbar"]) }
        if let videoTrack = media?.videoTrack { _ = pc.add(videoTrack, streamIds: ["crossbar"]) }

        if shouldOffer {
            append("policy: offering to \(peerId.prefix(8)) after appending tracks")
            makeOffer(peerId)
        } else {
            append("policy: awaiting an offer from \(peerId.prefix(8))")
        }
    }

    private func makeOffer(_ peerId: String) {
        guard let pc = peers[peerId] else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.offer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                guard let sdp else {
                    self.append("offer failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                pc.setLocalDescription(sdp) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.append("setLocalDescription(offer) failed: \(error.localizedDescription)")
                            return
                        }
                        self.append("offer -> \(peerId.prefix(8)) (\(sdp.sdp.count) chars, \(Self.mLines(sdp.sdp)))")
                        self.emit("relaySDP", [
                            "peer_id": peerId,
                            "session_description": ["type": "offer", "sdp": sdp.sdp],
                        ])
                    }
                }
            }
        }
    }

    private func makeAnswer(_ peerId: String, to offer: RTCSessionDescription) {
        guard let pc = peers[peerId] else { return }
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        pc.answer(for: constraints) { [weak self] sdp, error in
            Task { @MainActor in
                guard let self else { return }
                guard let sdp else {
                    self.append("answer failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                pc.setLocalDescription(sdp) { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        if let error {
                            self.append("setLocalDescription(answer) failed: \(error.localizedDescription)")
                            return
                        }
                        self.append("answer -> \(peerId.prefix(8)) (\(sdp.sdp.count) chars, \(Self.mLines(sdp.sdp)))")
                        self.emit("relaySDP", [
                            "peer_id": peerId,
                            "session_description": ["type": "answer", "sdp": sdp.sdp],
                        ])
                    }
                }
            }
        }
    }

    private func handleSessionDescription(_ payload: [String: Any]) {
        guard
            let peerId = payload["peer_id"] as? String,
            let description = payload["session_description"] as? [String: Any],
            let typeString = description["type"] as? String,
            let sdp = description["sdp"] as? String
        else { return }
        guard let pc = peers[peerId] else {
            append("sessionDescription from unknown peer \(peerId.prefix(8))")
            return
        }
        let type: RTCSdpType
        switch typeString {
        case "offer": type = .offer
        case "answer": type = .answer
        default: type = .prAnswer
        }
        append("\(typeString) <- \(peerId.prefix(8)) (\(sdp.count) chars, \(Self.mLines(sdp)))")

        pc.setRemoteDescription(RTCSessionDescription(type: type, sdp: sdp)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.append("setRemoteDescription failed: \(error.localizedDescription)")
                    return
                }
                // The audited contract flushes queued candidates immediately after a
                // successful setRemoteDescription, and that is the only flush point:
                // SDP and ICE are unordered on the wire.
                self.flushCandidates(peerId)
                if type == .offer { self.makeAnswer(peerId, to: RTCSessionDescription(type: type, sdp: sdp)) }
            }
        }
    }

    private func handleIceCandidate(_ payload: [String: Any]) {
        guard
            let peerId = payload["peer_id"] as? String,
            let candidate = payload["ice_candidate"] as? [String: Any],
            let sdp = candidate["candidate"] as? String
        else { return }
        // The contract sends only sdpMLineIndex and candidate; sdpMid is absent.
        let lineIndex = (candidate["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
        let ice = RTCIceCandidate(sdp: sdp, sdpMLineIndex: lineIndex, sdpMid: nil)

        guard let pc = peers[peerId], pc.remoteDescription != nil else {
            pendingCandidates[peerId, default: []].append(ice)
            return
        }
        pc.add(ice) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.append("addIceCandidate failed: \(error.localizedDescription)") }
        }
    }

    private func flushCandidates(_ peerId: String) {
        guard let pc = peers[peerId], let queued = pendingCandidates[peerId], !queued.isEmpty else { return }
        pendingCandidates[peerId] = []
        append("flushing \(queued.count) queued candidates to \(peerId.prefix(8))")
        for candidate in queued { pc.add(candidate) { _ in } }
    }

    private func removePeer(_ peerId: String) {
        guard let pc = peers.removeValue(forKey: peerId) else { return }
        pc.close()
        pendingCandidates[peerId] = nil
        inboundBytes[peerId] = nil
        outboundBytes[peerId] = nil
        remoteVideo[peerId] = nil
        remoteNames[peerId] = nil
        // Otherwise the label keeps claiming a call that has no peers left in it.
        if peers.isEmpty { state = "joined (no peers)" }
        append("removePeer \(peerId.prefix(8)) — connection closed")
    }

    private func peerId(for pc: RTCPeerConnection) -> String? {
        peers.first(where: { $0.value === pc })?.key
    }

    // MARK: - Measurement

    /// The only measure here that shows media rather than negotiation. A completed
    /// exchange with silent m-lines looks identical to a working call everywhere
    /// else — which is exactly the defect found in the audio-seam probe.
    private func startStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollStats() }
        }
    }

    private func pollStats() {
        for (peerId, pc) in peers {
            pc.statistics { [weak self] report in
                // Every inbound kind, not just audio. Reporting only audio made a live
                // video call look like it was carrying no picture, because a video
                // call's inbound video bytes never appeared anywhere in the log.
                var inbound: [String: (bytes: Int, energy: Double)] = [:]
                for (_, stat) in report.statistics {
                    guard stat.type == "inbound-rtp",
                          let kind = stat.values["kind"] as? String,
                          inbound[kind] == nil
                    else { continue }
                    let bytes = (stat.values["bytesReceived"] as? NSNumber)?.intValue ?? 0
                    let energy = (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0
                    inbound[kind] = (bytes, energy)
                }
                // What this device is *sending*, which is the other half of a question
                // inbound bytes cannot answer: whether audio keeps flowing when the app
                // is in the background and the camera has been taken away. Video going
                // flat there is expected; audio going flat is a dropped call.
                var outbound: [String: Int] = [:]
                for (_, stat) in report.statistics {
                    guard stat.type == "outbound-rtp",
                          let kind = stat.values["kind"] as? String,
                          outbound[kind] == nil
                    else { continue }
                    outbound[kind] = (stat.values["bytesSent"] as? NSNumber)?.intValue ?? 0
                }
                let path = Self.selectedPairDescription(report)
                let tailnet = Self.tailnetPairs(report)
                Task { @MainActor in
                    guard let self else { return }
                    if let path, self.reportedPath[peerId] != path {
                        self.reportedPath[peerId] = path
                        self.append("ICE path [\(peerId.prefix(8))] \(path)")
                    }
                    for entry in tailnet {
                        if !self.reportedTailnetPairs.contains(entry) {
                            self.reportedTailnetPairs.insert(entry)
                            self.append("TAILNET PAIR [\(peerId.prefix(8))] \(entry)")
                        }
                    }
                    for kind in inbound.keys.sorted() {
                        guard let stat = inbound[kind] else { continue }
                        let previous = self.inboundBytes[peerId]?[kind] ?? stat.bytes
                        let delta = stat.bytes - previous
                        self.inboundBytes[peerId, default: [:]][kind] = stat.bytes
                        let energy = String(format: "%.3f", stat.energy)
                        self.append("media IN <- \(peerId.prefix(8)) \(kind) bytes=\(stat.bytes) delta=\(delta) energy=\(energy)")
                    }
                    for kind in outbound.keys.sorted() {
                        guard let bytes = outbound[kind] else { continue }
                        let previous = self.outboundBytes[peerId]?[kind] ?? bytes
                        let delta = bytes - previous
                        self.outboundBytes[peerId, default: [:]][kind] = bytes
                        self.append("media OUT -> \(peerId.prefix(8)) \(kind) bytes=\(bytes) delta=\(delta)")
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    /// Which candidate pair is actually carrying the media, for **every** transport.
    ///
    /// An earlier revision reported `statistics.values.first(where: { $0.type ==
    /// "transport" })`; dictionary iteration order is arbitrary, so with more than one
    /// transport it returned a different one each poll and two pairs appeared to
    /// alternate. ICE selects one pair per transport, and only naming them all shows
    /// which path actually carried media.
    nonisolated private static func selectedPairDescription(_ report: RTCStatisticsReport) -> String? {
        var parts: [String] = []
        for transport in report.statistics.values.filter({ $0.type == "transport" }).sorted(by: { $0.id < $1.id }) {
            guard
                let pairId = transport.values["selectedCandidatePairId"] as? String,
                let pair = report.statistics[pairId]
            else { continue }

            func describe(_ key: String) -> String {
                guard
                    let id = pair.values[key] as? String,
                    let candidate = report.statistics[id]
                else { return "?" }
                let type = candidate.values["candidateType"] as? String ?? "?"
                let address = candidate.values["address"] as? String ?? "?"
                let port = (candidate.values["port"] as? NSNumber)?.intValue ?? 0
                let proto = candidate.values["protocol"] as? String ?? "?"
                return "\(type) \(address):\(port)/\(proto)"
            }

            let state = pair.values["state"] as? String ?? "?"
            let bytesSent = (pair.values["bytesSent"] as? NSNumber)?.intValue ?? -1
            parts.append(
                "[\(transport.id)] local=\(describe("localCandidateId")) "
                    + "remote=\(describe("remoteCandidateId")) state=\(state) bytesSent=\(bytesSent)"
            )
        }
        return parts.isEmpty ? nil : parts.joined(separator: " | ")
    }

    /// Every candidate pair that involves a Tailscale address, with its state.
    ///
    /// This is the question the selected pair cannot answer. Whether the overlay can
    /// carry media is exactly whether a pair between this device's tailnet address and
    /// the peer's ever reaches `succeeded` — and ICE checks all pairs, so that is
    /// observable even when a LAN pair wins the nomination. Reading the selected pair
    /// alone kept producing a LAN answer that said nothing either way.
    nonisolated private static func tailnetPairs(_ report: RTCStatisticsReport) -> [String] {
        func addr(_ key: String, _ pair: RTCStatistics) -> String {
            guard
                let id = pair.values[key] as? String,
                let candidate = report.statistics[id]
            else { return "?" }
            return candidate.values["address"] as? String ?? "?"
        }
        func isTailnet(_ value: String) -> Bool {
            value.hasPrefix("100.") || value.hasPrefix("fd7a:115c:a1e0")
        }

        var out: [String] = []
        for pair in report.statistics.values where pair.type == "candidate-pair" {
            let local = addr("localCandidateId", pair)
            let remote = addr("remoteCandidateId", pair)
            guard isTailnet(local) || isTailnet(remote) else { continue }
            let state = pair.values["state"] as? String ?? "?"
            let bytesSent = (pair.values["bytesSent"] as? NSNumber)?.intValue ?? 0
            let bytesReceived = (pair.values["bytesReceived"] as? NSNumber)?.intValue ?? 0
            out.append("\(local) <-> \(remote) state=\(state) sent=\(bytesSent) recv=\(bytesReceived)")
        }
        return out.sorted()
    }

    private static func iceServers(from raw: Any?) -> [RTCIceServer] {
        guard let list = raw as? [[String: Any]] else { return [] }
        return list.compactMap { entry in
            let urls: [String]
            if let one = entry["urls"] as? String { urls = [one] }
            else if let many = entry["urls"] as? [String] { urls = many }
            else { return nil }
            if let username = entry["username"] as? String,
               let credential = entry["credential"] as? String {
                return RTCIceServer(urlStrings: urls, username: username, credential: credential)
            }
            return RTCIceServer(urlStrings: urls)
        }
    }

    /// `v=0…` -> `2 m-lines (audio,video)`, so the log shows what was actually
    /// negotiated without printing an SDP.
    ///
    /// Splits on newlines by predicate, not on `"\n"`: in Swift `"\r\n"` is a single
    /// `Character`, so an SDP's CRLF-terminated lines never match a `"\n"` separator
    /// and the whole document appears to be one line. That made an earlier run report
    /// `0 m-lines` for an offer that plainly had two.
    private static func mLines(_ sdp: String) -> String {
        let kinds = sdp.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("m=") }
            .map { String($0.dropFirst(2).split(separator: " ").first ?? "") }
        return "\(kinds.count) m-lines (\(kinds.joined(separator: ",")))"
    }

    // MARK: - Logging

    private func append(_ line: String, detail: String? = nil) {
        lines.append(line)
        if lines.count > 60 { lines.removeFirst(lines.count - 60) }
        writeToLogFile(detail ?? line)
    }

    /// Pulled with devicectl rather than read off a screenshot; screen-only output
    /// has already cost measurements on this project. One file per peer so the two
    /// sides of a mesh exchange can be compared.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("signal-\(label).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

extension MiroTalkSignalClient: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {
        Task { @MainActor in
            guard let peerId = self.peerId(for: pc) else { return }
            // Our own candidates were previously only emitted, never logged, which
            // left no record of what this device actually offered.
            self.append("local candidate [\(peerId.prefix(8))] \(candidate.sdp)")
            self.emit("relayICE", [
                "peer_id": peerId,
                "ice_candidate": [
                    "sdpMLineIndex": Int(candidate.sdpMLineIndex),
                    "candidate": candidate.sdp,
                ],
            ])
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor in
            self.append("remote stream <- \(self.peerId(for: pc)?.prefix(8) ?? "?") (\(stream.audioTracks.count)a/\(stream.videoTracks.count)v)")
            self.startStatsPolling()
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {
        let raw = stateChanged.rawValue
        Task { @MainActor in
            self.append("signaling state -> \(raw) [\(self.peerId(for: pc)?.prefix(8) ?? "?")]")
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        let raw = newState.rawValue
        Task { @MainActor in
            self.append("pc state -> \(raw) [\(self.peerId(for: pc)?.prefix(8) ?? "?")]")
            if raw == 2 {
                // The screen said "join sent — awaiting addPeer/serverInfo" for a whole
                // call, because `state` was last written during the join and nothing
                // moved it afterwards. A label that describes the join rather than the
                // call is the same kind of lie as a log line that reports a failure
                // without saying what failed.
                self.state = "in a call"
                self.startStatsPolling()
            }
        }
    }

    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        let raw = newState.rawValue
        Task { @MainActor in self.append("ice state -> \(raw) [\(self.peerId(for: pc)?.prefix(8) ?? "?")]") }
    }

    // Required by the protocol; nothing to do.
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ pc: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Optional, worth reporting.
    nonisolated func peerConnection(
        _ pc: RTCPeerConnection,
        didAdd receiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        let kind = receiver.track?.kind ?? "?"
        let track = receiver.track
        Task { @MainActor in
            guard let peerId = self.peerId(for: pc) else { return }
            self.append("remote \(kind) track <- \(peerId.prefix(8))")
            if let video = track as? RTCVideoTrack {
                self.remoteVideo[peerId] = video
            }
            self.startStatsPolling()
        }
    }
}
