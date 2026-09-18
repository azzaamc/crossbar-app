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

    /// Whether the call in progress was placed from here.
    ///
    /// Needed because CallKit's two directions are told apart by which API reports the
    /// connection: an answered incoming call is marked connected when its answer action
    /// is fulfilled, while an outgoing one has to be told. Reporting the wrong
    /// direction is not merely redundant — `reportOutgoingCall` on an incoming call is
    /// the wrong API for it.
    private var isOutgoingCall = false
    private var logHandle: FileHandle?

    /// The call **this device** is in, if any.
    ///
    /// Family Call's identity is a person, not a device: `/api/bootstrap` answers "am I
    /// in a call?" identically for every client that authenticates as that person — a
    /// second phone, a simulator, an Xcode preview. So the server cannot tell this
    /// device whether *it* was in the call, and the client has to remember. Without
    /// this, launching any instance silently joins the live call, which is exactly what
    /// happened on 2026-09-18: an Xcode preview appeared as a third participant in a
    /// real call, with a black camera and a peer whose video never loaded on the other
    /// end. Resuming is now scoped to a call this device actually joined.
    private static let deviceCallKey = "crossbar.currentCallID"

    private var deviceCallID: String? {
        get { UserDefaults.standard.string(forKey: Self.deviceCallKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: Self.deviceCallKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.deviceCallKey)
            }
        }
    }

    init() {
        client.log = { [weak self] in self?.log($0) }
        wireCallKit()
        media.prepareAudioSession()
    }

    // MARK: - CallKit wiring

    private func wireCallKit() {
        callKit.onStart = { [weak self] callID, handle in
            guard let self else { return }
            self.isOutgoingCall = true
            self.callKitCallID = callID
            Task { await self.createCall(toContactID: handle) }
        }
        callKit.onAnswer = { [weak self] _ in
            self?.log("CallKit answered")
            Task { await self?.accept() }
        }
        callKit.onEnd = { [weak self] _ in
            self?.log("CallKit ended the call")
            Task { await self?.endFromCallKit() }
        }
        callKit.onMute = { [weak self] _, muted in
            self?.setMuted(muted)
        }
        callKit.onReset = { [weak self] in
            guard let self else { return }
            self.log("CallKit reset the provider — every call is gone")
            self.notice = "The call was reset by the system."
            self.callKitCallID = nil
            Task { await self.tearDown() }
        }
        callKit.onAudioActivated = { [weak self] session in
            guard let self else { return }
            let applied = self.media.adoptAudioSession(session)
            // Logged because echo is invisible in every other signal we collect: the
            // session once sat in SoloAmbient/Default, which engages no voice processing
            // and so cancels no echo, and every metric stayed healthy throughout.
            self.log(
                "\(applied) — live category=\(session.category.rawValue) "
                    + "mode=\(session.mode.rawValue) sampleRate=\(Int(session.sampleRate))"
            )
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

            // A call **this device** is already in — the app was closed or the phone
            // rang while it was suspended. Not just any active call: every instance
            // authenticating as this person sees the same active call, and joining it
            // is how a preview ended up in a real one.
            if let ongoing = bootstrap.ongoingCalls.first(where: { $0.id == deviceCallID && isMine($0) && $0.isActive }) {
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

    #if DEBUG
    /// Asks CallKit to place a call to an invitee who is not a contact, so the provider
    /// registration, the start-call transaction and the callback are all exercised
    /// without any phone ringing: the service refuses the invite before it notifies
    /// anybody (`403 CONTACT_NOT_ALLOWED`).
    ///
    /// This is the one genuinely new failure surface the product shell introduced. The
    /// debug flow called the API directly, so a rejected CallKit transaction would have
    /// gone unnoticed; here it is the first step of every outgoing call.
    func runCallKitSelfTest() {
        guard phase.call == nil else { return }
        log("self-test: asking CallKit to place a call")
        _ = callKit.startOutgoing(handle: "crossbar-selftest")
    }
    #endif

    private func createCall(toContactID contactID: String) async {
        do {
            log("placing a call to \(displayName(for: contactID))")
            let envelope = try await client.createCall(inviteeIds: [contactID])
            phase = .outgoing(envelope.call)
            deviceCallID = envelope.call.id
            connect(using: envelope.joinUrl)
        } catch {
            log("could not place the call: \(error.localizedDescription)")
            await abandonCall(reason: error.localizedDescription)
        }
    }

    /// Gives up on a call that never connected, **including on CallKit's side**.
    ///
    /// Tearing down only our own state is not enough: CallKit is already showing an
    /// outgoing call, and leaving it there means the system says a call is happening
    /// while the app knows it is not. The self-test caught exactly that on the device —
    /// a refused create left an outgoing call on screen that would never connect.
    private func abandonCall(reason: String) async {
        notice = reason
        if let callID = callKitCallID { callKit.end(callID: callID) }
        await tearDown()
    }

    // MARK: - Answering

    private func accept() async {
        guard let call = phase.call else { return }
        do {
            let envelope = try await client.respond(callId: call.id, accepted: true)
            phase = .inCall(envelope.call)
            deviceCallID = envelope.call.id
            // Deliberately no `reportConnected` here. CallKit marks an answered incoming
            // call connected when its answer action is fulfilled, and the API used to
            // report a connection is `reportOutgoingCall` — the wrong direction for a
            // call this side did not place.
            connect(using: envelope.joinUrl)
        } catch {
            // A 409 here is ordinary — answered elsewhere, declined, or expired.
            log("could not accept: \(error.localizedDescription)")
            await abandonCall(reason: error.localizedDescription)
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
        deviceCallID = nil
        isOutgoingCall = false
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
            deviceCallID = envelope.call.id
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

    /// Keeps the event stream up, and re-reads state whenever it comes back.
    ///
    /// The server sends no event ids and keeps no replay (`src/server.js:236-255`), so
    /// whatever happens while the stream is down is simply lost — the only way to learn
    /// of it is to ask again. Without this the app goes permanently deaf the first time
    /// the connection drops, which on a phone is routine: the stream is the *only* way
    /// an incoming call can arrive, since there is no push yet.
    private func startEvents() {
        eventsTask?.cancel()
        eventsTask = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled {
                for await event in self.client.events() {
                    if Task.isCancelled { return }
                    failures = 0
                    self.handle(event)
                }
                if Task.isCancelled { return }

                failures += 1
                let delay = min(30, Int(pow(2, Double(failures))))
                self.eventsDown = true
                self.log("event stream down — reconnecting in \(delay)s")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self.refreshState()
            }
        }
    }

    /// Re-reads what the stream could not replay.
    ///
    /// An invitation that arrived while the stream was down is still ringing
    /// server-side, and `/api/bootstrap` is the only thing that can say so — the call's
    /// own event was delivered once, to nobody.
    private func refreshState() async {
        guard phase.call == nil else { return }
        do {
            let bootstrap = try await client.bootstrap()
            contacts = bootstrap.contacts
            log("re-read state: \(bootstrap.calls.count) open call(s)")

            if let pending = bootstrap.calls.first(where: { $0.myStatus == "invited" }) {
                log("an invitation was waiting while the stream was down")
                ring(pending)
            } else if let ongoing = bootstrap.ongoingCalls.first(where: { $0.id == deviceCallID && $0.isActive }) {
                await resume(ongoing)
            }
        } catch {
            log("could not re-read state: \(error.localizedDescription)")
        }
    }

    /// Puts an incoming call on screen and hands it to CallKit.
    ///
    /// Shared by the live event and the re-read, because a call that arrived while the
    /// stream was down has to ring exactly like one that did not.
    private func ring(_ call: FamilyCall) {
        guard case .ready = phase else {
            log("invitation \(call.id) arrived while busy — ignored")
            return
        }
        log("incoming call \(call.id) from \(displayName(for: call.callerId)) status=\(call.status)")
        phase = .ringing(call)
        isOutgoingCall = false
        if let callID = UUID(uuidString: call.id) {
            callKitCallID = callID
            callKit.reportIncoming(callID: callID, callerName: displayName(for: call.callerId))
            log("reported to CallKit")
        } else {
            log("call id is not a UUID — CallKit cannot be told about it")
        }
    }

    private func handle(_ event: FamilyEvent) {
        switch event {
        case .ready:
            eventsDown = false

        case .incomingCall(let call):
            guard call.participants?.contains(where: { $0.userId == me?.id }) ?? false else {
                log("invitation \(call.id) ignored — not a participant")
                return
            }
            ring(call)

        case .callStatus(let call):
            guard let current = phase.call, current.id == call.id else { return }
            log("call status -> \(call.status)")
            if Self.isTerminal(call.status) {
                // Tell CallKit as well, or the system keeps showing a call the service
                // has already finished — a call that is over on one side and ringing on
                // the other is the worst of both. Our own state is cleared first so the
                // resulting end action does not try to end a call that is already gone.
                log("call is over (\(call.status)) — clearing")
                let stale = callKitCallID
                Task { await tearDown() }
                if let stale { callKit.end(callID: stale) }
            } else if call.isActive, !Self.isInCall(phase) {
                phase = .inCall(call)
                // Only an outgoing call has to be told it connected; an incoming one is
                // marked connected by CallKit itself. See `isOutgoingCall`.
                if isOutgoingCall, let callID = callKitCallID {
                    callKit.reportConnected(callID: callID)
                }
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
