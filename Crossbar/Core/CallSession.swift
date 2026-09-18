import AVFAudio
import Combine
import Foundation
import WebRTC

/// The product call state machine: who you are, who you can call, one call at a time,
/// and the media engine behind it.
///
/// **Every user action routes through CallKit**, which then calls back in. That is not
/// ceremony — CallKit owns the audio session, and it is what puts the call on the lock
/// screen, the route picker and the buttons on a headset. An app that answers a call
/// behind CallKit's back leaves the system showing a call that is not happening, so the
/// answer button on the system UI is the one that counts and the screens here mirror
/// that state rather than competing with it.
@MainActor
final class CallSession: ObservableObject {
    /// Where the session is. Not a boolean: an outgoing call and an incoming one need
    /// different affordances, and collapsing them is how a UI ends up offering to
    /// answer a call the user started.
    enum Phase: Equatable {
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

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var me: FamilyUser?
    @Published private(set) var contacts: [FamilyContact] = []
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraEnabled = true
    /// Surfaced rather than swallowed. A socket that has quietly died looks exactly
    /// like a quiet one, and this project has already lost a measurement to that.
    @Published private(set) var eventsDown = false
    @Published private(set) var notice: String?

    let media = CallMediaSource()
    let signal = MiroTalkSignalClient(label: "call")

    private let client = FamilyCallClient()
    private let callKit = CallKitController()
    private var eventsTask: Task<Void, Never>?
    private var callKitCallID: UUID?
    private var logHandle: FileHandle?

    init() {
        client.log = { [weak self] in self?.log($0) }
        wireCallKit()
        media.prepareAudioSession()
    }

    // MARK: - CallKit wiring

    private func wireCallKit() {
        callKit.onStart = { [weak self] callID, handle in
            guard let self else { return }
            self.callKitCallID = callID
            Task { await self.createCall(toContactID: handle) }
        }
        callKit.onAnswer = { [weak self] _ in
            Task { await self?.accept() }
        }
        callKit.onEnd = { [weak self] _ in
            Task { await self?.endFromCallKit() }
        }
        callKit.onMute = { [weak self] _, muted in
            self?.setMuted(muted)
        }
        callKit.onReset = { [weak self] in
            guard let self else { return }
            self.notice = "The call was reset by the system."
            Task { await self.tearDown() }
        }
        callKit.onAudioActivated = { [weak self] session in
            self?.media.adoptAudioSession(session)
            self?.log("audio session adopted from CallKit")
        }
        callKit.onAudioDeactivated = { [weak self] session in
            self?.media.releaseAudioSession(session)
            self?.log("audio session returned to CallKit")
        }
        callKit.onError = { [weak self] message in
            self?.log("callkit: \(message)")
            self?.notice = message
        }
    }

    // MARK: - Load

    func load() async {
        phase = .loading
        notice = nil
        eventsDown = false
        eventsTask?.cancel()

        do {
            let session = try await client.checkSession()
            guard session.authenticated, session.configured else {
                phase = .failed(
                    session.authenticated
                        ? "This Tailscale identity is not enrolled in Family Call."
                        : "No Tailscale identity. Check that Tailscale is connected."
                )
                return
            }

            let bootstrap = try await client.bootstrap()
            me = bootstrap.user
            contacts = bootstrap.contacts
            phase = .ready
            startEvents()

            // A call this person is already in — the app was closed or the phone rang
            // while it was suspended. Rejoining is what a phone does here.
            if let ongoing = bootstrap.ongoingCalls.first(where: { isMine($0) && $0.isActive }) {
                await resume(ongoing)
            }
        } catch {
            log("load failed: \(error.localizedDescription)")
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: - Placing

    /// Asks CallKit to place the call; `onStart` then creates it. Nothing here touches
    /// the API, so there is no path to a ring that the system does not know about.
    func placeCall(to contact: FamilyContact) {
        guard phase.call == nil else { return }
        notice = nil
        _ = callKit.startOutgoing(handle: contact.id)
    }

    private func createCall(toContactID contactID: String) async {
        do {
            log("placing a call to \(displayName(for: contactID))")
            let envelope = try await client.createCall(inviteeIds: [contactID])
            phase = .outgoing(envelope.call)
            connect(using: envelope.joinUrl)
        } catch {
            log("could not place the call: \(error.localizedDescription)")
            notice = error.localizedDescription
            await tearDown()
        }
    }

    // MARK: - Answering

    private func accept() async {
        guard let call = phase.call, let callID = callKitCallID else { return }
        do {
            let envelope = try await client.respond(callId: call.id, accepted: true)
            phase = .inCall(envelope.call)
            callKit.reportConnected(callID: callID)
            connect(using: envelope.joinUrl)
        } catch {
            // A 409 here is ordinary — answered elsewhere, declined, or expired.
            log("could not accept: \(error.localizedDescription)")
            notice = error.localizedDescription
            await tearDown()
        }
    }

    /// Ends the call, going through CallKit so the system UI agrees.
    func end() {
        guard let callID = callKitCallID else {
            Task { await tearDown() }
            return
        }
        callKit.end(callID: callID)
    }

    func decline() {
        end()
    }

    /// CallKit has ended the call, whether the user tapped End on the system UI or the
    /// app asked for it. A ringing call is declined; an answered one is ended.
    private func endFromCallKit() async {
        var wasRinging = false
        if case .ringing = phase { wasRinging = true }

        if let call = phase.call {
            if wasRinging {
                _ = try? await client.respond(callId: call.id, accepted: false)
            } else {
                try? await client.end(callId: call.id)
            }
        }
        await tearDown()
    }

    private func tearDown() async {
        signal.disconnect()
        media.stopCapture()
        callKitCallID = nil
        isMuted = false
        isCameraEnabled = true
        if case .failed = phase { return }
        phase = .ready
    }

    /// Rejoins a call that is already active. `/join` is the only route that accepts a
    /// participant into an active call, and it also marks `joined_at` server-side.
    private func resume(_ call: FamilyCall) async {
        do {
            log("rejoining an active call")
            let envelope = try await client.join(callId: call.id)
            phase = .inCall(envelope.call)
            if let callID = UUID(uuidString: envelope.call.id) { callKitCallID = callID }
            connect(using: envelope.joinUrl)
        } catch {
            log("could not rejoin: \(error.localizedDescription)")
        }
    }

    // MARK: - Media

    private func connect(using joinUrl: String?) {
        guard let joinUrl else {
            log("no joinUrl for this call")
            notice = "The call did not return a room."
            return
        }
        guard let target = JoinTarget(joinUrl: joinUrl) else {
            log("could not read the room from the join URL")
            notice = "The call's room could not be read."
            return
        }
        log("room \(target.room) on \(target.origin.absoluteString)")
        signal.media = media
        signal.originOverride = target.origin
        signal.peerName = me?.displayName
        log(media.startCapture())
        signal.connect(room: target.room)
    }

    func setMuted(_ muted: Bool) {
        isMuted = muted
        media.audioTrack.isEnabled = !muted
    }

    /// Routed through CallKit so the system's mute button and this one agree.
    func toggleMute() {
        guard let callID = callKitCallID else {
            setMuted(!isMuted)
            return
        }
        callKit.setMuted(!isMuted, callID: callID)
    }

    func toggleCamera() {
        isCameraEnabled.toggle()
        media.videoTrack.isEnabled = isCameraEnabled
    }

    func switchCamera() {
        log(media.switchCamera())
    }

    // MARK: - Events

    private func startEvents() {
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
        case .ready:
            eventsDown = false

        case .incomingCall(let call):
            guard call.participants?.contains(where: { $0.userId == me?.id }) ?? false else { return }
            guard case .ready = phase else {
                log("another invitation arrived while busy — ignoring")
                return
            }
            phase = .ringing(call)
            callKitCallID = UUID(uuidString: call.id)
            if let callKitCallID {
                callKit.reportIncoming(
                    callID: callKitCallID,
                    callerName: displayName(for: call.callerId)
                )
            }

        case .callStatus(let call):
            guard let current = phase.call, current.id == call.id else { return }
            log("call status -> \(call.status)")
            if Self.isTerminal(call.status) {
                Task { await tearDown() }
            } else if call.isActive, !Self.isInCall(phase) {
                phase = .inCall(call)
                if let callID = callKitCallID { callKit.reportConnected(callID: callID) }
            }

        case .ongoingCall(let call):
            // Broadcast to every connected user, not only participants, so membership
            // has to be checked before believing it.
            guard isMine(call), call.isActive, phase.call == nil else { return }
            Task { await resume(call) }

        case .presence(let userId, let online):
            guard let index = contacts.firstIndex(where: { $0.id == userId }) else { return }
            contacts[index].online = online

        case .unrecognised:
            break

        case .failed(let reason):
            // No event ids and no replay: whatever was missed while the stream was
            // down cannot be recovered from it, only re-read.
            eventsDown = true
            log("events stopped: \(reason)")
        }
    }

    // MARK: - Helpers

    private func isMine(_ call: FamilyCall) -> Bool {
        call.callerId == me?.id || (call.participants?.contains { $0.userId == me?.id } ?? false)
    }

    func displayName(for userId: String) -> String {
        if userId == me?.id { return me?.displayName ?? "You" }
        return contacts.first { $0.id == userId }?.displayName ?? "A family member"
    }

    private static func isTerminal(_ status: String) -> Bool {
        ["ended", "cancelled", "declined", "missed"].contains(status)
    }

    private static func isInCall(_ phase: Phase) -> Bool {
        if case .inCall = phase { return true }
        return false
    }

    // MARK: - Logging

    private func log(_ line: String) {
        #if DEBUG
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("session.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        if let data = (line + "\n").data(using: .utf8) { logHandle?.write(data) }
        #endif
    }
}
