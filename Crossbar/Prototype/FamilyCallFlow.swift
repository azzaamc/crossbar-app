#if DEBUG
import Combine
import Foundation
import SwiftUI
import WebRTC

/// Drives one real Family Call end to end: identity, contacts, placing, answering,
/// and the media engine that carries the result.
///
/// This is the product flow exercised through a debug surface. The pieces it
/// composes were each measured separately on hardware — identity through Serve,
/// native signalling against production MiroTalk, peer connections against a real
/// browser peer — and what is new here is only the order they are called in.
@MainActor
final class FamilyCallFlow: ObservableObject {
    /// Where the flow is. Deliberately not a boolean: `outgoing` and `ringing` need
    /// different buttons, and collapsing them is how a UI ends up offering "Answer"
    /// on a call the user started.
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case outgoing(FamilyCall)
        case ringing(FamilyCall)
        case inCall(FamilyCall)
        case failed(String)

        var call: FamilyCall? {
            switch self {
            case .outgoing(let call), .ringing(let call), .inCall(let call): return call
            default: return nil
            }
        }
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var me: FamilyUser?
    @Published private(set) var contacts: [FamilyContact] = []
    @Published private(set) var resumable: FamilyCall?
    /// True when the event stream is down. Surfaced rather than swallowed: a socket
    /// that has silently died looks exactly like a quiet one, which cost a
    /// measurement in the signalling probe.
    @Published private(set) var eventsDown = false
    @Published private(set) var lines: [String] = []

    let media = CallMediaSource()
    let signal = MiroTalkSignalClient(label: "call")

    private let client: FamilyCallClient
    private var eventsTask: Task<Void, Never>?
    private var logHandle: FileHandle?

    init() {
        client = FamilyCallClient()
        client.log = { [weak self] in self?.append($0) }
    }

    // MARK: - Load

    func load() async {
        phase = .loading
        eventsDown = false
        eventsTask?.cancel()
        append("loading identity and contacts")
        // Not fatal if it fails — it answers a product question, not a precondition.
        _ = try? await client.pushConfig()

        do {
            let session = try await client.checkSession()
            guard session.authenticated, session.configured else {
                let reason = session.authenticated
                    ? "Identity reached the service but is not enrolled with it."
                    : "No Tailscale identity. Is Tailscale connected on this device?"
                append("cannot continue: \(reason)")
                phase = .failed(reason)
                return
            }

            let bootstrap = try await client.bootstrap()
            me = bootstrap.user
            contacts = bootstrap.contacts
            phase = .ready

            // A call the app was already in when it last stopped. Offered rather than
            // joined automatically: joining is a decision, and the stream has no
            // replay, so nothing here can know what happened in the meantime.
            resumable = bootstrap.ongoingCalls.first { isMine($0) && $0.isActive }
            if let resumable {
                append("an active call from \(displayName(for: resumable.callerId)) can be rejoined")
            }

            // An invitation that arrived while the app was not running.
            if let pending = bootstrap.calls.first(where: { $0.myStatus == "invited" }) {
                phase = .ringing(pending)
                append("an unanswered invitation is still open")
            }

            startEvents()
        } catch {
            append("load failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Placing a call

    /// **This rings a real phone.** The confirmation lives in the view, not here, so
    /// that no code path can reach the API without a person having chosen to.
    func placeCall(to contact: FamilyContact) async {
        do {
            append("placing a call to \(contact.displayName)")
            let envelope = try await client.createCall(inviteeIds: [contact.id])
            phase = .outgoing(envelope.call)
            connect(using: envelope.joinUrl)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Answering

    func accept() async {
        guard let call = phase.call else { return }
        do {
            let envelope = try await client.respond(callId: call.id, accepted: true)
            phase = .inCall(envelope.call)
            connect(using: envelope.joinUrl)
        } catch {
            // A 409 here is ordinary: the call was declined elsewhere, expired, or
            // already answered on another device.
            append("could not accept: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    func decline() async {
        guard let call = phase.call else { return }
        do {
            _ = try await client.respond(callId: call.id, accepted: false)
            append("declined \(call.id)")
        } catch {
            append("could not decline: \(error.localizedDescription)")
        }
        phase = .ready
    }

    /// Rejoin a call that is already active. `/join` is the only route that accepts a
    /// participant who was invited to an active call, and it is also what marks
    /// `joined_at` server-side.
    func rejoin() async {
        guard let call = resumable else { return }
        do {
            let envelope = try await client.join(callId: call.id)
            phase = .inCall(envelope.call)
            resumable = nil
            connect(using: envelope.joinUrl)
        } catch {
            append("could not rejoin: \(error.localizedDescription)")
            resumable = nil
        }
    }

    /// Ends the call **for everyone**. The backend has no per-participant leave
    /// (`src/server.js:328-340`), so there is no "leave quietly" to offer here, and
    /// that is a product decision the four-person case will force.
    func hangUp() async {
        let call = phase.call ?? resumable
        disconnectMedia()
        if let call {
            do {
                try await client.end(callId: call.id)
            } catch {
                append("could not end the call: \(error.localizedDescription)")
            }
        }
        resumable = nil
        phase = .ready
    }

    // MARK: - Media

    private func connect(using joinUrl: String?) {
        guard let joinUrl else {
            append("no joinUrl for this call — the room coordinates never arrived")
            return
        }
        guard let target = JoinTarget(joinUrl: joinUrl) else {
            append("could not read the room from the join URL")
            return
        }
        append("room \(target.room) on \(target.origin.absoluteString)")
        signal.media = media
        signal.originOverride = target.origin
        signal.peerName = me?.displayName
        append(media.startCapture())
        signal.connect(room: target.room)
    }

    private func disconnectMedia() {
        signal.disconnect()
        media.stopCapture()
    }

    // MARK: - Events

    private func startEvents() {
        append("subscribing to /api/events")
        eventsTask = Task { [weak self] in
            guard let self else { return }
            for await event in self.client.events() {
                if Task.isCancelled { return }
                self.handle(event)
            }
        }
    }

    private func handle(_ event: FamilyEvent) {
        switch event {
        case .ready(let userId):
            eventsDown = false
            append("events ready for \(userId)")

        case .incomingCall(let call):
            // Only invitations to us are actionable; the broadcast is per-user, but
            // nothing here should trust that.
            guard call.participants?.contains(where: { $0.userId == me?.id }) ?? false else { return }
            guard case .ready = phase else {
                append("another invitation arrived while \(phase) — ignoring")
                return
            }
            phase = .ringing(call)
            append("incoming call from \(displayName(for: call.callerId))")

        case .callStatus(let call):
            guard let current = phase.call, current.id == call.id else { return }
            append("call status -> \(call.status)")
            if Self.isTerminal(call.status) {
                disconnectMedia()
                phase = .ready
            } else if call.isActive, !Self.isInCall(phase) {
                // Fires both when the other side accepts and when this side placed a
                // call that has since gone active. The room is open to both in either
                // case, so the screen should stop saying "Calling".
                append("call is active — both sides can be in the room")
                phase = .inCall(call)
            }

        case .ongoingCall(let call):
            // Broadcast to every connected user, not only to participants, so the
            // only safe reading is to check membership before believing it.
            guard isMine(call), call.isActive, phase.call == nil else { return }
            resumable = call
            append("\(displayName(for: call.callerId)) has an active call")

        case .presence(let userId, let online):
            guard let index = contacts.firstIndex(where: { $0.id == userId }) else { return }
            let contact = contacts[index]
            contacts[index] = FamilyContact(
                id: contact.id,
                displayName: contact.displayName,
                relationship: contact.relationship,
                avatar: contact.avatar,
                lastSeen: contact.lastSeen,
                online: online
            )

        case .unrecognised(let name):
            append("event \(name) (not handled)")

        case .failed(let reason):
            // No event ids and no replay: whatever was missed while the stream was
            // down cannot be recovered from it. Only a re-read can.
            eventsDown = true
            append("events stopped: \(reason) — reload to re-read state")
        }
    }

    // MARK: - Helpers

    private func isMine(_ call: FamilyCall) -> Bool {
        call.callerId == me?.id || (call.participants?.contains { $0.userId == me?.id } ?? false)
    }

    private func displayName(for userId: String) -> String {
        if userId == me?.id { return me?.displayName ?? "you" }
        return contacts.first { $0.id == userId }?.displayName ?? String(userId.prefix(12))
    }

    private static func isTerminal(_ status: String) -> Bool {
        ["ended", "cancelled", "declined", "missed"].contains(status)
    }

    private static func isInCall(_ phase: Phase) -> Bool {
        if case .inCall = phase { return true }
        return false
    }

    // MARK: - Logging

    func append(_ line: String) {
        lines.append(line)
        if lines.count > 80 { lines.removeFirst(lines.count - 80) }
        writeToLogFile(line)
    }

    /// Same reasoning as the other instruments: results are pulled with `devicectl`
    /// rather than read off a screenshot, because a screenshot has already failed to
    /// capture a measurement on this project.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("familycall.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

/// The debug surface for the real control plane.
///
/// Placing a call rings someone's phone, so the confirmation is in front of the
/// action rather than buried in it.
struct FamilyCallSection: View {
    @StateObject private var flow = FamilyCallFlow()
    @State private var expanded = false
    @State private var confirming: FamilyContact?

    var body: some View {
        DisclosureGroup("Control plane (service)", isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Placing a call rings a real phone. Do not run this at the same time as the seam capture — the camera is shared.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Load identity and contacts") {
                        Task { await flow.load() }
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("family.load")
                }

                Text(status)
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("family.status")

                if flow.eventsDown {
                    Text("Event stream is down — press Load to re-read state.")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }

                if let me = flow.me {
                    Text("You are \(me.displayName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                actions

                videoArea

                if !flow.contacts.isEmpty {
                    contactsList
                }

                Text(flow.lines.suffix(14).joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .padding(.top, 4)
        }
        .font(.caption)
        // Gated rather than run on every appear: this probe is also opened for the
        // seam and signalling measurements, and opening an SSE stream and calling the
        // API on every launch would muddy those. An environment variable for the same
        // reason the other overrides use one — `devicectl` passes those cleanly,
        // while a leading-dash launch argument is parsed as a devicectl option.
        //   xcrun devicectl device process launch … -e '{"CROSSBAR_AUTOLOAD":"1"}'
        .task {
            let gate = ProcessInfo.processInfo.environment["CROSSBAR_AUTOLOAD"] ?? "unset"
            flow.append("section appeared, autoload=\(gate)")
            if gate == "1" {
                await flow.load()
            }
        }
        .confirmationDialog(
            confirming.map { "Call \($0.displayName)? This rings their phone now." } ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            if let contact = confirming {
                Button("Call \(contact.displayName)") {
                    let chosen = contact
                    confirming = nil
                    Task { await flow.placeCall(to: chosen) }
                }
                Button("Cancel", role: .cancel) { confirming = nil }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch flow.phase {
        case .ringing(let call):
            HStack {
                Button("Accept") { Task { await flow.accept() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("family.accept")
                Button("Decline", role: .destructive) { Task { await flow.decline() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("family.decline")
                Text("from \(call.callerId.prefix(12))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

        case .outgoing, .inCall:
            Button("End call", role: .destructive) { Task { await flow.hangUp() } }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("family.end")

        default:
            if flow.resumable != nil {
                Button("Rejoin the active call") { Task { await flow.rejoin() } }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("family.rejoin")
            }
        }
    }

    /// Shown once a call exists, because before that there is nothing to render and a
    /// black rectangle reads as a fault.
    @ViewBuilder
    private var videoArea: some View {
        if flow.phase.call != nil {
            CallVideoGrid(signal: flow.signal, localTrack: flow.media.videoTrack)
                .frame(height: 230)
        }
    }

    private var contactsList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(flow.contacts) { contact in
                HStack {
                    Circle()
                        .fill(contact.online ? Color.green : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                    Text(contact.displayName)
                        .font(.caption)
                    Spacer()
                    Button("Call") { confirming = contact }
                        .buttonStyle(.bordered)
                        .disabled(flow.phase.call != nil)
                        .accessibilityIdentifier("family.call.\(contact.id)")
                }
            }
        }
    }

    private var status: String {
        switch flow.phase {
        case .idle: return "Idle"
        case .loading: return "Loading…"
        case .ready: return "Ready — \(flow.contacts.count) contacts"
        case .outgoing(let call): return "Calling — \(call.status)"
        case .ringing(let call): return "Incoming call — \(call.status)"
        case .inCall(let call): return "In a call — \(call.status)"
        case .failed(let reason): return "Failed — \(reason)"
        }
    }
}
#endif
