import Combine
import Foundation
import TailscaleKit
import UIKit

/// The family network this app carries with it.
///
/// Family Call is reachable **only** over the tailnet. The service binds loopback and is
/// published through Tailscale Serve on a `*.ts.net` name that resolves nowhere else,
/// and its API refuses a request that arrives without the identity headers Serve
/// injects — so a client has to be on the tailnet, and there is no URL to hand to a
/// device that is not.
///
/// Until this existed, "on the tailnet" meant asking a family member to install the
/// Tailscale app and keep it connected. This replaces that: the app runs its own
/// userspace tsnet node, authorises once through a login page, and dials the private
/// service through the node's SOCKS loopback.
///
/// ## What it carries, and what it structurally cannot
///
/// The distinction is not a configuration choice, so it is worth stating where the code
/// lives rather than only in a document:
///
///  - **It carries the control plane and the signalling socket.** Both are HTTP, and
///    both are dialled through the loopback — see `CallTransport`.
///  - **It cannot carry media.** A userspace node has no network interface
///    (`"TUN":false`, `using fake (no-op) tun device`), so libwebrtc in this process
///    cannot gather a candidate on the overlay: the node's own address never appeared
///    among the 55 candidates gathered during a node-carried call, while the system
///    tunnel's address did. The call still runs — its audio and video take the ordinary
///    WebRTC path, DTLS-SRTP encrypted, peer to peer over the device's own interfaces —
///    but the media does not ride the overlay. Measured 2026-09-19, recorded in
///    `docs/TAILSCALE_KIT_PROBE.md`.
///
/// ## One node per process
///
/// A node owns a device identity and a state directory under `Documents/tailscale`, so a
/// second instance pointed at the same path would fight the first for both. Everything
/// that needs a node — the product and the DEBUG instruments alike — goes through
/// `shared`.
@MainActor
final class TailnetNode: ObservableObject {
    static let shared = TailnetNode()

    /// Where the node is, as the UI and the product state machine need to see it.
    enum State: Equatable {
        case idle
        /// Bring-up is in flight. It stays here while the node waits to be authorised,
        /// which is why the login URL is published separately rather than folded in.
        case starting
        case running
        case failed(String)

        var isRunning: Bool { self == .running }
    }

    @Published private(set) var state: State = .idle

    /// The page that authorises this device, once the IPN bus has delivered one.
    ///
    /// Kept apart from `state` deliberately: `up()` blocks until the login finishes, so a
    /// first run is *simultaneously* "starting" and "waiting for a human". A UI that had
    /// to choose one would either hide the URL or claim the node was up.
    @Published private(set) var loginURL: String?

    /// Consumers of the node's log.
    ///
    /// Several exist — the product session that owns the app's log file, and the DEBUG
    /// instrument that draws bring-up on screen. A single closure would let whichever set
    /// it last silently take the log from the other, and the node's own account of what it
    /// is doing is the evidence this whole branch ran on.
    private var logConsumers: [(String) -> Void] = []

    func addLogConsumer(_ consumer: @escaping (String) -> Void) {
        logConsumers.append(consumer)
    }

    private var node: TailscaleNode?
    private var bringUp: Task<Void, Never>?
    private var busProcessor: MessageProcessor?

    /// Re-establishes the bus subscription while the node still needs authorising.
    private var loginWatch: Task<Void, Never>?

    private var nodeLogFD: Int32?

    /// The carrier handed out for the node that is currently up.
    ///
    /// Cached because the loopback is what a session dials and it does not change while
    /// the node lives. It is *not* trusted: see `verifyOrRebuild`.
    private var carrier: CallTransport?

    /// An auth key, when one has been stored.
    ///
    /// The login page is the path this is built around — a first run sends someone to
    /// Tailscale and that is the whole enrolment. A key is the shortcut for repeated
    /// device runs, where a fresh install would otherwise mean a fresh approval every
    /// time. It is stored in this app's defaults, never compiled in and never logged.
    private static let authKeyDefaultsKey = "TailscaleAuthKey"

    var authKeyEntry = ""

    private var authKey: String? {
        if let stored = UserDefaults.standard.string(forKey: Self.authKeyDefaultsKey),
           !stored.isEmpty {
            return stored
        }
        let env = ProcessInfo.processInfo.environment["TAILSCALE_AUTH_KEY"]
        return (env?.isEmpty == false) ? env : nil
    }

    /// The knock the carrier-readiness check uses.
    ///
    /// Any `/api/session` answer counts, whatever its status: the question is whether the
    /// path carried a request and returned one, not whether it was authorised. This is
    /// the endpoint the control plane uses anyway, so a carrier that passes here is a
    /// carrier the product can use.
    private var probeURL: URL { FamilyCallService.baseURL.appendingPathComponent("api/session") }

    /// Whether the node is deliberately not used.
    ///
    /// `CROSSBAR_TAILNET_NODE=off` dials direct, for an instrument that needs to compare
    /// the two routes or work while the node cannot be authorised. It is an override
    /// rather than a fallback: nothing selects it silently, because a run that took the
    /// system's route while the screen said otherwise is the exact failure this project
    /// keeps finding.
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["CROSSBAR_TAILNET_NODE"] != "off"
    }

    // MARK: - Lifecycle

    /// Brings the node up, once, however many callers ask.
    ///
    /// `up()` returns only once the node is authorised, so concurrent callers wait on the
    /// single bring-up rather than racing a second node into the same state directory.
    func start() async {
        if let bringUp {
            await bringUp.value
            return
        }
        let task = Task { await self.bringUpNode() }
        bringUp = task
        await task.value
        bringUp = nil
    }

    private func bringUpNode() async {
        guard node == nil else {
            log("node already running")
            return
        }

        let path = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale", isDirectory: true)
        try? FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)

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
            state = .starting
            log(authKey == nil
                ? "starting the embedded node — an unapproved device will need a login page"
                : "starting the embedded node with a stored auth key")

            // The bus is watched *before* `up()`, because `up()` is the thing that blocks
            // waiting for the login this bus delivers. Started afterwards, it would miss
            // the only event it exists to catch.
            await watchLoginBus(for: node)

            // `up()` does not return until the node is authorised, so the status poll runs
            // alongside it rather than after: without that, a node with no auth key parks
            // forever and never reveals the URL that would authorise it.
            let watcher = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.refreshStatus()
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            defer { watcher.cancel() }

            try await node.up()
            state = .running
            loginURL = nil
            log("node is up")
        } catch {
            log("bring-up failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
            self.node = nil
        }
    }

    func stop() async {
        loginWatch?.cancel()
        loginWatch = nil
        busProcessor?.cancel()
        busProcessor = nil
        if let node { try? await node.close() }
        node = nil
        carrier = nil
        state = .idle
        loginURL = nil
        log("node closed")
    }

    // MARK: - The carrier

    /// The carrier for a running node, waiting until it has actually carried a request.
    ///
    /// Readiness is not `node != nil`, and not `up()` having returned either. A node
    /// object exists from the first moment of bring-up, and the loopback listener accepts
    /// connections before anything can be carried over it: measured 2026-09-18, a call
    /// launched while the system Tailscale app was disconnected dialled the loopback ~11 s
    /// before `node is up` appeared and both sockets died with
    /// `A TLS error caused the secure connection failed` — against a status document that
    /// still said `no peers`. So this waits for a request that went through the SOCKS path
    /// and came back.
    func attach() async throws -> CallTransport {
        await start()

        guard let node else {
            throw TailnetError.nodeUnavailable(reason: describeState())
        }
        if let carrier, state.isRunning, await carriesARequest(carrier) {
            return carrier
        }

        let (configuration, loopback) = try await URLSessionConfiguration.tailscaleSession(node)
        let transport = CallTransport(configuration: configuration,
                                      label: "node \(loopback.address)",
                                      loopbackAddress: loopback.address)

        var last = "nothing was attempted"
        for attempt in 1...10 {
            if await carriesARequest(transport) {
                if attempt > 1 { log("carrier \(loopback.address) answered on attempt \(attempt)") }
                carrier = transport
                return transport
            }
            last = "no answer"
            try? await Task.sleep(nanoseconds: 500_000_000)
        }

        log("carrier \(loopback.address) carried nothing in 10 attempts — last: \(last)")
        throw TailnetError.loopbackUnavailable(address: loopback.address)
    }

    /// Checks whether the current carrier still answers, and rebuilds the node when it
    /// does not.
    ///
    /// This is the failure the whole embedded-node question turned on. A suspended node
    /// can come back `Running` with a loopback that no longer answers: measured once
    /// after a ten-minute suspension, and **not** reproduced in an identical run the next
    /// day. So the failure is intermittent and no amount of clock-watching predicts it,
    /// which means the cached address cannot be trusted after a suspension at all — the
    /// app verifies, and rebuilds when the verify fails.
    ///
    /// `loopback()` caches for the node's life with no invalidation and no API to clear
    /// it, and nothing exposes the listener, so the only recovery is a new node. That is
    /// cheap: the machine key is on disk, so the replacement authorises without a login
    /// and brings a new loopback with it.
    ///
    /// Returns whether the carrier changed, which is the caller's cue to re-dial anything
    /// holding a socket.
    @discardableResult
    func verifyOrRebuild(reason: String) async -> Bool {
        if let carrier, await carriesARequest(carrier) { return false }
        guard node != nil else { return false }

        // Rebuilt only when the node itself still reports `Running`. A backend that is
        // not running means the network went away rather than the listener, and
        // rebuilding on every failed request would turn an outage into a bring-up loop.
        guard await backendState() == "Running" else {
            log("not rebuilding: the node is \(await backendState() ?? "unreadable"), so the network is the problem")
            return false
        }

        log("rebuilding the node: \(reason)")
        await stop()
        do {
            _ = try await attach()
            return true
        } catch {
            log("rebuild failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Whether a carrier carries a request and comes back with an HTTP answer.
    private func carriesARequest(_ transport: CallTransport) async -> Bool {
        var request = URLRequest(url: probeURL)
        request.setValue("application/json", forHTTPHeaderField: "accept")
        request.timeoutInterval = 5
        do {
            let (_, response) = try await transport.session().data(for: request)
            return response is HTTPURLResponse
        } catch {
            return false
        }
    }

    // MARK: - Status

    /// The node's `BackendState`, through the LocalAPI path that never touches the
    /// loopback — which is what makes it readable when the loopback is the thing that
    /// broke.
    func backendState() async -> String? {
        guard let data = await statusJSON(),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        return object["BackendState"] as? String
    }

    /// The raw status document, for the instruments that read byte counters out of it.
    func statusJSON() async -> Data? {
        try? await node?.statusJSON()
    }

    private func refreshStatus() async {
        guard let node else { return }
        do {
            let data = try await node.statusJSON()
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let backend = object["BackendState"] as? String ?? "?"
            let auth = (object["AuthURL"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            if let auth, auth != loginURL { loginURL = auth }
            // A node parked at NeedsLogin would otherwise report the same state every
            // three seconds and bury everything else.
            if backend != lastReportedBackend {
                lastReportedBackend = backend
                log("BackendState=\(backend)")
                if let auth { log("login URL ready — open it to authorise this device") }
            }
        } catch {
            log("status unreadable: \(error.localizedDescription)")
        }
    }

    private var lastReportedBackend: String?

    private func describeState() -> String {
        switch state {
        case .idle: return "not started"
        case .starting: return loginURL == nil ? "starting" : "waiting to be authorised"
        case .running: return "running"
        case .failed(let reason): return reason
        }
    }

    // MARK: - Authorisation

    /// Subscribes to the IPN bus, which is where the login URL lives, and keeps it alive
    /// until the node is up.
    ///
    /// `statusJSON()` carries an `AuthURL` field and it was empty on every poll while the
    /// node sat at NeedsLogin, so the status document is not the source. The bus is, and
    /// `BrowseToURL` is the field — which makes it the only way a first run can be
    /// authorised at all, and therefore worth keeping rather than subscribing once.
    ///
    /// The subscription is re-established because the bus is a long poll and ends by
    /// itself: measured on the device 2026-09-19, one ended after about a minute with
    /// `The request timed out` against `localapi/v0/watch-ipn-bus`. A first run that dropped
    /// it there would be a device that needs authorising, with no page to open.
    private func watchLoginBus(for node: TailscaleNode) async {
        let watcher = IPNBusWatcher(
            report: { [weak self] line in
                Task { @MainActor in self?.log(line) }
            },
            onLoginURL: { [weak self] url in
                Task { @MainActor in
                    guard let self else { return }
                    self.loginURL = url
                    self.log("login URL ready — open it to authorise this device")
                }
            })

        loginWatch = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, !self.state.isRunning else { return }
                self.busProcessor?.cancel()
                do {
                    let client = LocalAPIClient(localNode: node, logger: nil)
                    self.busProcessor = try await client.watchIPNBus(mask: [.initialState, .prefs],
                                                                     consumer: watcher)
                } catch {
                    self.log("could not watch the IPN bus: \(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: 15_000_000_000)
            }
        }
    }

    /// Opens the authorisation page. The user does the authorising; nothing here can.
    @discardableResult
    func openLoginPage() -> Bool {
        guard let loginURL, let url = URL(string: loginURL) else { return false }
        UIApplication.shared.open(url)
        return true
    }

    func saveAuthKey() {
        let trimmed = authKeyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        UserDefaults.standard.set(trimmed, forKey: Self.authKeyDefaultsKey)
        authKeyEntry = ""
        log("auth key stored in this app's defaults")
    }

    func clearAuthKey() {
        UserDefaults.standard.removeObject(forKey: Self.authKeyDefaultsKey)
        log("auth key cleared from this app's defaults")
    }

    // MARK: - Logging

    func log(_ line: String) {
        for consumer in logConsumers { consumer(line) }
    }

    /// The go backend writes to this descriptor from its own threads, so it gets a file
    /// of its own rather than sharing a line buffer. A descriptor the go runtime writes
    /// to must stay open for the node's life.
    private func makeNodeLogger() -> LogSink {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("tailscale-node.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        nodeLogFD = fd
        return NodeLogSink(fd: fd < 0 ? nil : fd)
    }
}

/// The ways the embedded node can refuse to carry something.
enum TailnetError: LocalizedError {
    case nodeUnavailable(reason: String)
    case loopbackUnavailable(address: String)

    var errorDescription: String? {
        switch self {
        case .nodeUnavailable(let reason):
            return "The family network is not up — \(reason)"
        case .loopbackUnavailable(let address):
            return "The family network is up but \(address) never answered, so nothing was dialled."
        }
    }
}

/// Taps the IPN bus for the one thing the status document does not carry: the login URL.
///
/// An actor because `MessageConsumer` requires one, and because the bus delivers from the
/// network stack rather than the main actor. Only changes are reported upward — the bus
/// re-sends the current state with every notification, and forwarding each one would
/// bury the log.
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

/// `nonisolated` because `LogSink` is called from the network stack, not the main actor,
/// and this app defaults unannotated declarations to `MainActor`.
private struct NodeLogSink: LogSink {
    let fd: Int32?

    nonisolated var logFileHandle: Int32? { fd }

    nonisolated func log(_ message: String) {
        guard let fd else { return }
        let bytes = Array(("crossbar: " + message + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
    }
}
