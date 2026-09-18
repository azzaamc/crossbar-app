#if DEBUG
import Combine
import Foundation
import SwiftUI
import TailscaleKit
import UIKit

/// Can Crossbar carry its own tailnet, so a family member never has to install and
/// sign in to the Tailscale app?
///
/// Every measurement so far was taken on macOS, where `URLSession` and this wrapper
/// are the same code but the *platform* is not. The open questions are all iOS-only:
///
///  1. Does a userspace tsnet node come up and authorise inside an app sandbox?
///  2. Does its SOCKS loopback actually carry the control plane and the MiroTalk
///     WebSocket, which is the whole reason for embedding it?
///  3. Does any of that survive the app being suspended? This is the one that
///     matters commercially — a call app spends its life in the background, and
///     the existing signalling instrument already proved that a suspended app's
///     WebSocket dies silently, with no close frame and no error.
///
/// On (3) there is a specific, documented reason to expect trouble. `proxyVia`
/// reaches the node through `TailscaleNode.loopback()`, which caches the address
/// on first call and never invalidates it. Upstream's own comment on `statusJSON`
/// says the OS reclaims that loopback TCP listener from a suspended process on
/// iOS, "where the cached loopback address goes permanently stale". The cached
/// value is visible here as `loopback=…` on every check, so staleness would show
/// up as an address that stops working rather than an error that explains itself.
///
/// This is a measurement instrument, not product code. Nothing in the product asks
/// for a node yet; every symbol here is DEBUG-only.
@MainActor
final class TailscaleProbe: NSObject, ObservableObject {
    /// One node per app, not one per screen.
    ///
    /// A node owns a device identity and a state directory, so a second instance
    /// pointed at the same path would fight the first for both. The instrument screen
    /// and the launch-time entry point below therefore share this one.
    static let shared = TailscaleProbe()

    @Published private(set) var status = "Not started"
    @Published private(set) var lines: [String] = []
    @Published private(set) var authURL: String?
    @Published var authKeyEntry = ""

    private var node: TailscaleNode?
    private var logHandle: FileHandle?
    private var nodeLogFD: Int32?

    /// The IPN bus subscription. Retained for the node's life: dropping it would end
    /// the long-poll and with it the only source of the login URL.
    private var busProcessor: MessageProcessor?

    /// Last status reported to the log, so the timed poll only writes on change.
    private var lastStatusSummary: String?

    /// The raw status document is written once per node, not once per poll.
    private var loggedRawStatus = false

    /// The Family Call deployment, matching the backend reachability probe so a
    /// different host needs no edit here.
    private var backendBase: URL {
        ProcessInfo.processInfo.environment["CROSSBAR_BACKEND_URL"]
            .flatMap(URL.init(string:))
            ?? URL(string: "https://qatar-vpn.tailea67b0.ts.net:8443")!
    }

    /// MiroTalk's own listener is a separate port from the API, so it gets its own
    /// override rather than being derived from the one above.
    private var socketURL: URL {
        ProcessInfo.processInfo.environment["CROSSBAR_SOCKET_URL"]
            .flatMap(URL.init(string:))
            ?? URL(string: "wss://qatar-vpn.tailea67b0.ts.net/socket.io/?EIO=4&transport=websocket")!
    }

    /// No key is compiled in and none belongs in the repository. The node is
    /// authorised once; its state lives in the container afterwards, so this is
    /// only needed on a fresh install.
    private var authKey: String? {
        if let stored = UserDefaults.standard.string(forKey: Self.authKeyDefaultsKey),
           !stored.isEmpty {
            return stored
        }
        if let env = ProcessInfo.processInfo.environment["TAILSCALE_AUTH_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    private static let authKeyDefaultsKey = "TailscaleAuthKey"

    override init() {
        super.init()
        // Lifecycle is recorded rather than inferred: the span between these two
        // lines is the thing question (3) is about, and the timestamps matter more
        // than the order.
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.append("— didEnterBackground —") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.append("— willEnterForeground —")
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.node != nil else { return }
                self.append("— didBecomeActive, re-checking through the node —")
                // Re-checking automatically is the point: a real user does not tap a
                // button after switching back to the app.
                //
                // Both paths run, and the pair is what makes the result readable.
                // statusJSON() goes through tsnet's in-memory LocalAPI and does not
                // touch the loopback, so if the status still reports a running
                // backend while the request below fails, the node is alive and only
                // the cached loopback address has gone stale.
                Task {
                    await self.refreshStatus()
                    await self.check()
                }
            }
        }
    }

    // MARK: - Node lifecycle

    func start() async {
        guard node == nil else {
            append("node already running")
            return
        }

        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

        append("starting node in \(path.path)")
        append(authKey == nil
            ? "no auth key — expecting interactive login"
            : "using a stored auth key")

        let config = Configuration(hostName: "crossbar-ios",
                                   path: path.path,
                                   authKey: authKey,
                                   controlURL: kDefaultControlURL,
                                   // Not ephemeral: an ephemeral node leaves the tailnet
                                   // when it disconnects and would need authorising again
                                   // on every launch, which makes repeated device runs
                                   // useless.
                                   ephemeral: false)

        do {
            let node = try TailscaleNode(config: config, logger: makeNodeLogger())
            self.node = node
            status = "Bringing up…"

            // The bus is watched *before* `up()`, because `up()` is the thing that
            // blocks waiting for the login this bus delivers. Starting it afterwards
            // would be starting it after the only event it exists to catch.
            await startIPNBus(for: node)

            // `up()` does not return until the node is authorised — it blocks on login.
            // So the status poll runs *alongside* it rather than after: without that, a
            // node with no auth key parks forever and never reveals the URL that would
            // authorise it, which is exactly what the first device run did. The poll
            // also uses the in-memory LocalAPI path, which works before the node is in
            // the netmap and therefore before the loopback is useful.
            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshStatus()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            defer { watcher.cancel() }

            try await node.up()
            append("node is up")
            await refreshStatus()
        } catch {
            append("bring-up failed: \(error)")
            status = "Bring-up failed"
            self.node = nil
        }
    }

    func stop() async {
        guard let node else { return }
        busProcessor?.cancel()
        busProcessor = nil
        do {
            try await node.close()
            append("node closed")
            status = "Stopped"
        } catch {
            append("close failed: \(error)")
        }
        self.node = nil
        self.authURL = nil
    }

    func saveAuthKey() {
        let trimmed = authKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.authKeyDefaultsKey)
        authKeyEntry = ""
        append("auth key stored in this app's defaults")
    }

    func clearAuthKey() {
        UserDefaults.standard.removeObject(forKey: Self.authKeyDefaultsKey)
        append("auth key cleared from this app's defaults")
    }

    func openAuthURL() {
        guard let authURL, let url = URL(string: authURL) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Authorisation

    /// Subscribes to the IPN bus, which is where the login URL lives.
    ///
    /// `statusJSON()` carries an `AuthURL` field and it was empty on every poll while
    /// the node sat at NeedsLogin, so the status document is not the source. Upstream's
    /// README names the bus — "watch the ipn bus … for the browseToURL field for
    /// interactive web-based auth" — and this is the same mechanism the bundled
    /// example uses.
    ///
    /// This is the shape the product wants: a first run that sends someone to a
    /// Tailscale login page, rather than an auth key someone has to keep and hand out.
    private func startIPNBus(for node: TailscaleNode) async {
        let watcher = IPNBusWatcher(
            report: { [weak self] line in
                Task { @MainActor in self?.append(line) }
            },
            onLoginURL: { [weak self] url in
                Task { @MainActor in
                    guard let self else { return }
                    self.authURL = url
                    self.append("login URL ready — open it to authorise this device")
                    self.append(url)
                }
            })

        do {
            let client = LocalAPIClient(localNode: node, logger: nil)
            busProcessor = try await client.watchIPNBus(mask: [.initialState, .prefs],
                                                        consumer: watcher)
            append("watching the IPN bus for a login URL")
        } catch {
            append("could not watch the IPN bus: \(error)")
        }
    }

    // MARK: - Status

    func refreshStatus() async {
        guard let node else {
            append("no node — start it first")
            return
        }
        do {
            let data = try await node.statusJSON()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let backend = object["BackendState"] as? String ?? "?"
            let auth = (object["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ips = object["TailscaleIPs"] as? [String] ?? []

            status = "BackendState: \(backend)"
            authURL = auth

            // Dumped once. The status document is the only place the node's own view of
            // itself is visible, and the login URL that authorises a first run comes
            // from it or from nowhere — so a run that shows no AuthURL has to be able
            // to show what the document actually contained.
            if !loggedRawStatus {
                loggedRawStatus = true
                append("raw status: \(String(decoding: data, as: UTF8.self))")
            }

            // This runs on a timer for as long as the node waits to be authorised, so
            // lines are emitted on change only. A node parked at NeedsLogin would
            // otherwise write the same three lines every three seconds and bury
            // everything else in the log.
            let summary = "\(backend)|\(auth ?? "")|\(ips.joined(separator: ","))"
            guard summary != lastStatusSummary else { return }
            lastStatusSummary = summary

            append("BackendState=\(backend)")
            if let auth { append("AuthURL=\(auth)") }
            if !ips.isEmpty { append("IPs=\(ips.joined(separator: ", "))") }
        } catch {
            let text = "\(error)"
            guard text != lastStatusSummary else { return }
            lastStatusSummary = text
            append("status failed: \(text)")
        }
    }

    // MARK: - Traffic through the node

    /// Both halves of the wire contract, through one node.
    ///
    /// `tailscaleSession` re-reads the node's loopback each time, so the address
    /// printed here is the *cached* one. If the cached address goes stale after a
    /// suspend, that is exactly where it will show.
    func check() async {
        guard let node = self.node else {
            append("no node — start it first")
            return
        }

        append("— check —")

        var loopbackAddress = "?"
        do {
            let (config, loopback) = try await URLSessionConfiguration.tailscaleSession(node)
            loopbackAddress = loopback.address
            append("loopback=\(loopback.address)")
            let session = URLSession(configuration: config)

            // 1. The control plane, which is how identity is established at all.
            var request = URLRequest(url: backendBase.appendingPathComponent("api/session"))
            request.setValue("application/json", forHTTPHeaderField: "accept")
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            append("HTTP \(code)")

            if let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                let authenticated = json["authenticated"] as? Bool ?? false
                let name = (json["identity"] as? [String: Any])?["name"] as? String ?? "?"
                append("authenticated=\(authenticated) identity=\(name)")
                status = authenticated
                    ? "Identity resolves through the embedded node"
                    : "Reached the service, no identity (HTTP \(code))"
            } else {
                append("unparseable body (\(data.count) bytes)")
                status = "HTTP \(code)"
            }

            // 2. MiroTalk signalling. The Engine.IO handshake arrives on the first
            //    frame, so one receive separates success from silence — the same
            //    test the macOS spike used.
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
                : "connected, but frame is not the handshake")
        } catch {
            append("check failed at loopback=\(loopbackAddress): \(error.localizedDescription)")
            status = "Failed — \(error.localizedDescription)"
        }
    }

    // MARK: - Logging

    /// The go backend writes to this descriptor from its own threads, so it gets a
    /// file of its own: interleaving it into the probe's line buffer would corrupt
    /// both.
    private func makeNodeLogger() -> LogSink {
        let url = documentsDirectory.appendingPathComponent("tailscale-node.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        // A descriptor the go runtime writes to must stay open for the node's life.
        nodeLogFD = fd
        return NodeLogSink(fd: fd < 0 ? nil : fd)
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        writeToLogFile(line)
    }

    /// Screen-only output has already cost measurements twice, so everything also
    /// goes to Documents/tailscale.log for pulling.
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

/// Taps the IPN bus for the one thing the status document does not carry: the login URL.
///
/// An actor because `MessageConsumer` requires one, and because the bus delivers from
/// the network stack rather than the main actor. Only changes are reported upward — the
/// bus re-sends the current state with every notification, and forwarding each one
/// would bury the log.
private actor IPNBusWatcher: MessageConsumer {
    private let report: @Sendable (String) -> Void
    private let onLoginURL: @Sendable (String) -> Void

    private var lastState: Ipn.State?
    private var lastURL: String?

    init(report: @escaping @Sendable (String) -> Void,
         onLoginURL: @escaping @Sendable (String) -> Void) {
        self.report = report
        self.onLoginURL = onLoginURL
    }

    func notify(_ notify: Ipn.Notify) {
        if let state = notify.State, state != lastState {
            lastState = state
            report("bus state: \(state)")
        }
        if let url = notify.BrowseToURL, !url.isEmpty, url != lastURL {
            lastURL = url
            onLoginURL(url)
        }
    }

    func error(_ error: any Error) {
        report("bus error: \(error)")
    }
}

/// `nonisolated` because `LogSink` is called from the network stack, not the main
/// actor, and this app defaults unannotated declarations to `MainActor`.
private struct NodeLogSink: LogSink {
    let fd: Int32?

    nonisolated var logFileHandle: Int32? { fd }

    nonisolated func log(_ message: String) {
        guard let fd else { return }
        var bytes = Array(("probe: " + message + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
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
