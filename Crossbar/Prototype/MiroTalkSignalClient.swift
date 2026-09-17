#if DEBUG
import Combine
import Foundation
import SwiftUI

/// A native Engine.IO v4 / Socket.IO v5 client, reduced to the subset the audited
/// MiroTalk contract requires.
///
/// `docs/MIROTALK_CORE_AUDIT.md` determines what is sent and in what shape — the
/// `join` payload, `addPeer`, `relaySDP`/`sessionDescription`,
/// `relayICE`/`iceCandidate`, `removePeer` — but nothing has ever executed that
/// contract from native code. This instrument answers the first question only:
/// can a native client open the transport, complete both handshakes, and be
/// accepted into a room?
///
/// It deliberately does NOT create peer connections yet. Offer/answer policy is
/// the part the audit flags as undetermined, because Objective-C libwebrtc
/// exposes no `negotiationneeded`; mixing that into a transport probe would make
/// a failure ambiguous.
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
    @Published private(set) var roomId: String
    @Published var roomInput: String

    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private var logHandle: FileHandle?
    private var peerUUID = UUID().uuidString

    /// The private MiroTalk origin. Overridable so no deployment detail is baked in.
    private var origin: URL {
        ProcessInfo.processInfo.environment["CROSSBAR_MIROTALK_ORIGIN"]
            .flatMap(URL.init(string:))
            ?? URL(string: "https://qatar-vpn.tailea67b0.ts.net")!
    }

    override init() {
        let generated = UUID().uuidString
        roomId = generated
        roomInput = generated
        super.init()
    }

    // MARK: - Connection

    func connect() {
        disconnect()
        let room = roomInput.trimmingCharacters(in: .whitespacesAndNewlines)
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
        append("room=\(room)")
        append("connecting \(url.absoluteString)")

        let session = URLSession(configuration: .default)
        self.session = session
        let task = session.webSocketTask(with: url)
        self.task = task
        task.resume()

        receiveLoop(task)
    }

    func disconnect() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        state = "disconnected"
        append("disconnected")
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
            send("3") // pong; EIO v4 has the server ping
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
            emitJoin()
        case "2":
            append("event \(rest.prefix(600))")
        case "4":
            append("connect_error \(rest)")
            state = "rejected"
        case "3":
            append("ack \(rest.prefix(200))")
        default:
            append("socket.io \(type) \(rest.prefix(300))")
        }
    }

    // MARK: - Join

    /// The payload shape is taken from the audited contract
    /// (`docs/MIROTALK_CORE_AUDIT.md`, "join payload"). `peer_name` is left as a
    /// probe label rather than the family display name because this instrument is
    /// not yet an authenticated product client.
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
            "peer_name": "Crossbar Signal Probe",
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
        guard
            let data = try? JSONSerialization.data(withJSONObject: ["join", payload]),
            let json = String(data: data, encoding: .utf8)
        else {
            append("could not encode the join payload")
            return
        }
        append("emit join channel=\(roomId)")
        send("42\(json)")
        state = "join sent — awaiting addPeer/serverInfo"
    }

    // MARK: - Logging

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        writeToLogFile(line)
    }

    /// Pulled with devicectl rather than read off a screenshot; screen-only output
    /// has already cost measurements on this project.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("signal.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

struct SignalProbeSection: View {
    @StateObject private var client = MiroTalkSignalClient()
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("MiroTalk signalling (native Socket.IO)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("room id", text: $client.roomInput)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(.caption2.monospaced())

                HStack {
                    Button("Connect and join") { client.connect() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.connect")

                    Button("Disconnect") { client.disconnect() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("signal.disconnect")
                }

                Text(client.state)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(client.lines.joined(separator: "\n"))
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
