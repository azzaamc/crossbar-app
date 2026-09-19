#if DEBUG
import Combine
import Foundation
import SwiftUI
import TailscaleKit
import UIKit

/// The embedded node, as an instrument.
///
/// The node itself is **product code** now (`TailnetNode`): the app starts it at launch and
/// dials the control plane and the signalling socket through it, so no family member has to
/// install and sign in to the Tailscale app. What is left here is only the measuring — does
/// the loopback carry both halves of the wire contract, and what has the node itself put on
/// the wire?
///
/// It drives the app's node rather than owning one. A node holds a device identity and a
/// state directory under `Documents/tailscale`, and two of them pointed at the same path
/// fight over both, which is why there is one per process and this is a view onto it.
@MainActor
final class TailscaleProbe: NSObject, ObservableObject {
    static let shared = TailscaleProbe()

    @Published private(set) var status = "Not started"
    @Published private(set) var lines: [String] = []

    private let node = TailnetNode.shared
    private var cancellables = Set<AnyCancellable>()
    private var logHandle: FileHandle?

    /// Last peer totals read from the node, so a dump can report a delta.
    private var nodeTraffic: [String: (rx: Int64, tx: Int64)] = [:]

    /// The login URL, straight from the node that owns the bus subscription.
    var authURL: String? { node.loginURL }

    /// Mirrored for the text field, which binds to this object rather than the node.
    var authKeyEntry: String {
        get { node.authKeyEntry }
        set { node.authKeyEntry = newValue }
    }

    /// MiroTalk's own listener is a separate port from the API, so it gets its own
    /// override rather than being derived from the one above.
    private var socketURL: URL {
        ProcessInfo.processInfo.environment["CROSSBAR_SOCKET_URL"]
            .flatMap(URL.init(string:))
            ?? URL(string: "wss://qatar-vpn.tailea67b0.ts.net/socket.io/?EIO=4&transport=websocket")!
    }

    override init() {
        super.init()
        node.addLogConsumer { [weak self] line in
            Task { @MainActor in self?.append(line) }
        }
        node.$state
            .combineLatest(node.$loginURL)
            .sink { [weak self] state, login in
                guard let self else { return }
                switch state {
                case .idle: self.status = "Not started"
                case .starting: self.status = login == nil ? "Bringing up…" : "Waiting for a login"
                case .running: self.status = "Running"
                case .failed(let reason): self.status = "Failed — \(reason)"
                }
            }
            .store(in: &cancellables)
    }

    func start() async {
        await node.start()
    }

    func stop() async {
        await node.stop()
    }

    func saveAuthKey() { node.saveAuthKey() }
    func clearAuthKey() { node.clearAuthKey() }
    func openAuthURL() { node.openLoginPage() }

    // MARK: - Measurement

    /// Both halves of the wire contract, through one node.
    ///
    /// This is the check the branch exists on: the control plane, which is how identity is
    /// established at all, and the MiroTalk signalling WebSocket, which is how a call is
    /// arranged. Either one failing means the node is not a usable route, whatever its
    /// status document says.
    @discardableResult
    func check() async -> Bool {
        append("— check —")
        do {
            let carrier = try await node.attach()
            append("carrier=\(carrier.label) loopback=\(carrier.loopbackAddress ?? "?")")
            let session = carrier.session()

            // 1. The control plane.
            var request = URLRequest(url: FamilyCallService.baseURL.appendingPathComponent("api/session"))
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            append("HTTP \(code)")
            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let authenticated = json["authenticated"] as? Bool ?? false
                let name = (json["identity"] as? [String: Any])?["name"] as? String ?? "?"
                append("authenticated=\(authenticated) identity=\(name)")
            } else {
                append("unparseable body (\(data.count) bytes)")
            }

            // 2. MiroTalk signalling. The Engine.IO handshake arrives on the first frame, so
            //    one receive separates success from silence — the test the macOS spike used.
            let socket = session.webSocketTask(with: socketURL)
            socket.resume()
            defer { socket.cancel(with: .goingAway, reason: nil) }

            let frame = try await withThrowingTaskGroup(of: String.self) { group -> String in
                group.addTask {
                    switch try await socket.receive() {
                    case .string(let text): return text
                    case .data(let data): return String(decoding: data, as: UTF8.self)
                    @unknown default: return "<unknown frame>"
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                    throw NSError(domain: "tailscale-probe", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "no frame within 20s"])
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            append("ws first frame: \(frame.prefix(120))")
            append(frame.hasPrefix("0")
                ? "signalling handshake OK"
                : "connected, but the frame is not the handshake")
            return true
        } catch {
            append("check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// What the node itself has carried, from its own peer statistics.
    ///
    /// This is the measurement that separates "the socket was configured to use the node"
    /// from "the node carried it". The system Tailscale app is installed on this phone too,
    /// so a working socket proves a working route, not which one — and the candidate lists
    /// show the system tunnel's address while the node has no interface to offer at all.
    /// These counters only move for traffic the node itself put on the wire.
    ///
    /// The typed status document drops the byte counters, so this reads the raw JSON, which
    /// carries them. Totals are cumulative for the node's life and are reported as a delta
    /// against the previous reading: a single reading cannot say whether the call in front
    /// of it added anything.
    func logNodeTraffic(_ note: String) async {
        guard let data = await node.statusJSON() else {
            append("node traffic [\(note)] — no node")
            return
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let peers = object["Peer"] as? [String: [String: Any]] ?? [:]

        var carried: [String] = []
        for peer in peers.values {
            let rx = (peer["RxBytes"] as? NSNumber)?.int64Value ?? 0
            let tx = (peer["TxBytes"] as? NSNumber)?.int64Value ?? 0
            guard rx + tx > 0 else { continue }
            let name = peer["HostName"] as? String ?? "?"
            let previous = nodeTraffic[name] ?? (0, 0)
            nodeTraffic[name] = (rx, tx)
            carried.append("\(name) rx=\(rx)(+\(rx - previous.0)) tx=\(tx)(+\(tx - previous.1))")
        }

        if carried.isEmpty {
            // The field names are the thing that could be wrong here, and a silent zero
            // would read as a negative result rather than a missing one.
            let fields = peers.values.first.map { $0.keys.sorted().joined(separator: ",") }
                ?? "no peers in the status document"
            append("node traffic [\(note)] — nothing carried; peer fields: \(fields)")
        } else {
            append("node traffic [\(note)] — \(carried.sorted().joined(separator: "; "))")
        }
    }

    /// The node's own view of itself, as the raw document.
    func refreshStatus() async {
        guard let data = await node.statusJSON() else {
            append("no node — start it first")
            return
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let backend = object["BackendState"] as? String ?? "?"
        let ips = object["TailscaleIPs"] as? [String] ?? []
        append("BackendState=\(backend) ips=[\(ips.joined(separator: ", "))]")
    }

    // MARK: - Logging

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        writeToLogFile(line)
    }

    /// Screen-only output has already cost measurements twice, so everything also goes to
    /// `Documents/tailscale.log` for pulling.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let url = documentsDirectory.appendingPathComponent("tailscale.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

struct TailscaleProbeSection: View {
    @StateObject private var probe = TailscaleProbe.shared
    @State private var expanded = false

    var body: some View {
        DisclosureGroup("Embedded Tailscale node", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Start node") { Task { await probe.start() } }
                        .accessibilityIdentifier("tailscale.start")
                    Button("Check") { Task { await probe.check() } }
                        .accessibilityIdentifier("tailscale.check")
                    Button("Status") { Task { await probe.refreshStatus() } }
                        .accessibilityIdentifier("tailscale.status")
                    Button("Traffic") { Task { await probe.logNodeTraffic("manual") } }
                        .accessibilityIdentifier("tailscale.traffic")
                    Button("Stop") { Task { await probe.stop() } }
                        .accessibilityIdentifier("tailscale.stop")
                }
                .buttonStyle(.bordered)

                SecureField("tskey-auth-… (fresh install only)", text: $probe.authKeyEntry)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption2)

                HStack {
                    Button("Save key") { probe.saveAuthKey() }
                    Button("Clear key") { probe.clearAuthKey() }
                    if probe.authURL != nil {
                        Button("Open login") { probe.openAuthURL() }
                    }
                }
                .buttonStyle(.bordered)
                .font(.caption2)

                Text(probe.status)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(probe.lines.joined(separator: "\n"))
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
