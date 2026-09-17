#if DEBUG
import AVFoundation
import Combine
import Foundation
import SwiftUI
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
    @Published private(set) var lines: [String] = []

    /// Distinguishes the two probe peers in the log and to the server.
    let label: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var logHandle: FileHandle?
    private var roomId = ""
    private let peerUUID = UUID().uuidString

    // Peer connections, keyed by remote Socket.IO id, as the audited contract does.
    private var factory: RTCPeerConnectionFactory?
    private var peers: [String: RTCPeerConnection] = [:]
    private var pendingCandidates: [String: [RTCIceCandidate]] = [:]
    private var audioTrack: RTCAudioTrack?
    private var videoTrack: RTCVideoTrack?
    private var capturer: RTCCameraVideoCapturer?
    private var statsTimer: Timer?
    private var audioBytes: [String: Int] = [:]

    /// The private MiroTalk origin. Overridable so no deployment detail is baked in.
    private var origin: URL {
        ProcessInfo.processInfo.environment["CROSSBAR_MIROTALK_ORIGIN"]
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
        components.queryItems = [
            URLQueryItem(name: "EIO", value: "4"),
            URLQueryItem(name: "transport", value: "websocket"),
        ]
        guard let url = components.url else {
            append("could not build socket.io URL from \(origin.absoluteString)")
            return
        }

        state = "connecting"
        append("peer \(label) room=\(room) uuid=\(peerUUID.prefix(8))")
        append("connecting \(url.absoluteString)")

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        receiveLoop(task)
    }

    func disconnect() {
        statsTimer?.invalidate()
        statsTimer = nil
        for (_, pc) in peers { pc.close() }
        peers.removeAll()
        pendingCandidates.removeAll()
        audioBytes.removeAll()
        capturer?.stopCapture()
        capturer = nil
        audioTrack = nil
        videoTrack = nil
        factory = nil

        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = "disconnected"
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
            state = "joined-namespace"
            prepareMedia()
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
        case "removePeer": if let argument, let id = argument["peer_id"] as? String { removePeer(id) }
        default: break
        }
    }

    // MARK: - Media

    /// Separate factories, not shared with the audio-seam probe: two camera
    /// capturers in one process fight over the capture session. Do not run both
    /// instruments at once.
    private func prepareMedia() {
        guard factory == nil else { return }
        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.factory = factory
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        let audioSource = factory.audioSource(with: constraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "crossbar-audio")

        let videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource, trackId: "crossbar-video")
        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.capturer = capturer

        guard
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first
        else {
            append("media prepared (audio only — no capture device)")
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.last else {
            append("media prepared (audio only — no capture format)")
            return
        }
        capturer.startCapture(with: device, format: format, fps: 30)
        append("media prepared (audio + \(device.localizedName))")
    }

    // MARK: - Join

    /// The payload shape is taken from the audited contract
    /// (`docs/MIROTALK_CORE_AUDIT.md`, "join payload"). `peer_name` is a probe
    /// label rather than the family display name because this instrument is not
    /// yet an authenticated product client.
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
            "peer_name": "Crossbar \(label)",
            "peer_avatar": "",
            "peer_token": NSNull(),
            "peer_video": true,
            "peer_audio": true,
            "peer_video_status": true,
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

    // MARK: - Peering

    private func handleAddPeer(_ payload: [String: Any]) {
        guard
            let peerId = payload["peer_id"] as? String,
            let factory
        else { return }
        // The audited contract dedupes against existing connections.
        guard peers[peerId] == nil else {
            append("addPeer \(peerId.prefix(8)) ignored (already connected)")
            return
        }
        let shouldOffer = payload["should_create_offer"] as? Bool ?? false

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = Self.iceServers(from: payload["iceServers"])
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
        if let audioTrack { _ = pc.add(audioTrack, streamIds: ["crossbar"]) }
        if let videoTrack { _ = pc.add(videoTrack, streamIds: ["crossbar"]) }

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
        audioBytes[peerId] = nil
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
                var found: (bytes: Int, energy: Double)?
                for (_, stat) in report.statistics {
                    guard stat.type == "inbound-rtp",
                          let kind = stat.values["kind"] as? String
                    else { continue }
                    let bytes = (stat.values["bytesReceived"] as? NSNumber)?.intValue ?? 0
                    let energy = (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0
                    if kind == "audio", found == nil { found = (bytes, energy) }
                }
                Task { @MainActor in
                    guard let self else { return }
                    guard let found else { return }
                    let previous = self.audioBytes[peerId] ?? found.bytes
                    let delta = found.bytes - previous
                    self.audioBytes[peerId] = found.bytes
                    let energy = String(format: "%.3f", found.energy)
                    self.append("media IN <- \(peerId.prefix(8)) bytes=\(found.bytes) delta=\(delta) energy=\(energy)")
                }
            }
        }
    }

    // MARK: - Helpers

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
            if raw == 2 { self.startStatsPolling() }
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
        Task { @MainActor in
            self.append("remote \(kind) track <- \(self.peerId(for: pc)?.prefix(8) ?? "?")")
            self.startStatsPolling()
        }
    }
}

struct SignalProbeSection: View {
    @StateObject private var peerA = MiroTalkSignalClient(label: "A")
    @StateObject private var peerB = MiroTalkSignalClient(label: "B")
    @State private var expanded = false
    @State private var room = "crosstest"

    var body: some View {
        DisclosureGroup("MiroTalk signalling (native Socket.IO)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Do not run the seam capture at the same time — two camera capturers conflict.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                TextField("room id", text: $room)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.caption2.monospaced())

                HStack {
                    Button("A join") { peerA.connect(room: room) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.a.join")
                    Button("B join") { peerB.connect(room: room) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.b.join")
                    Button("Disconnect both") {
                        peerA.disconnect()
                        peerB.disconnect()
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("signal.disconnect")
                }

                Text("A: \(peerA.state)   B: \(peerB.state)")
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(peerA.lines.suffix(10).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)

                Text(peerB.lines.suffix(10).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
        }
        .font(.caption)
    }
}
#endif
