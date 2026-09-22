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
        /// The family network is waiting to be authorised. Not a failure and not a slow
        /// load: nothing else can be attempted until a human opens the login page, so the
        /// screen has to say so. The URL itself is published separately, because it
        /// arrives while this phase is already in force.
        case needsLogin
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

    /// Calls that have finished, newest first, for the Recents screen.
    ///
    /// Read beside the people, because it is the other thing the app has to show and it comes
    /// from the same service at the same moment. A history that cannot be read is not a
    /// reason to refuse the load: the people are what was asked for, and an empty Recents
    /// says nothing has happened rather than the whole app failing.
    @Published private(set) var history: [RecentCall] = []
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraEnabled = true
    @Published private(set) var isSpeakerOn = true
    /// Surfaced rather than swallowed. A socket that has quietly died looks exactly
    /// like a quiet one, and this project has already lost a measurement to that.
    @Published private(set) var eventsDown = false
    @Published private(set) var notice: String?

    let media = CallMediaSource()
    let signal = MiroTalkSignalClient(label: "call")

    private let client = FamilyCallClient()
    private let callKit = CallKitController()

    /// The family network this app carries with it.
    ///
    /// Shared rather than owned: a node holds a device identity and a state directory, so
    /// one per process is the only arrangement that does not leave two of them fighting
    /// over both. The DEBUG instruments use this same object, which is also why it is not
    /// created here.
    let node = TailnetNode.shared

    /// Where the carrier is, once a node has produced one. Held because a rebuild makes a
    /// new one, and everything dialling the old address has to be re-dialled.
    private var carrier: CallTransport?

    /// The family network's state, mirrored for the views.
    ///
    /// Mirrored rather than read through `node` where it is drawn, because a nested
    /// `ObservableObject` does not republish: a screen observing this session would never
    /// see the node change on its own.
    @Published private(set) var tailnetState: TailnetNode.State = .idle
    @Published private(set) var tailnetLoginURL: String?
    private var eventsTask: Task<Void, Never>?
    private var callKitCallID: UUID?

    /// The Picture-in-Picture window, armed while a call has video worth showing.
    let pip = CallPiPController()
    private var pipSourceView: UIView?
    private var cancellables = Set<AnyCancellable>()

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
        media.log = { [weak self] in self?.log("media: \($0)") }
        wireCallKit()
        wireSystemCamera()
        wireDeviceLock()
        wireTailnet()
        wireTailnetLifecycle()
        media.prepareAudioSession()
        pip.onLog = { [weak self] line in self?.log("PiP: \(line)") }
        // The remote track and the in-call tile arrive at different moments, and PiP needs
        // both, so arming is attempted whenever the tracks change.
        signal.$remoteVideo
            .sink { [weak self] tracks in
                guard let self, !tracks.isEmpty else { return }
                self.armPiP()
            }
            .store(in: &cancellables)
    }

    /// Reports the camera state the **system** allows, without touching what the user chose.
    ///
    /// iOS takes the camera from a backgrounded app, so a call that survives being left is
    /// already audio-only *here* — but the far end keeps drawing its last frame unless it
    /// is told, and "frozen picture" and "call broken" look identical there. So the camera
    /// status goes on the wire when the app leaves and again when it returns.
    ///
    /// `isCameraEnabled` is deliberately untouched: returning must restore what the user
    /// chose, not what the system permitted while they were away.
    private func wireSystemCamera() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logLifecycle("backgrounded")
                self?.reportCameraToRoom()
            }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.logLifecycle("active")
                self?.reportCameraToRoom()
            }
        }
    }

    /// The device locking is **not** the same event as being backgrounded, and the
    /// difference matters: a lock is not a reason for a call to end.
    ///
    /// Every one of these fires on an ordinary lock. Measured on 2026-09-20 with a live
    /// call in this app: locking produced `device locked`, `resigning active` and
    /// `entered the background`, and unlocking produced `returning to the foreground`
    /// and `device unlocked`, all of them with the app still `phase=inCall`. The call
    /// survived the lock — the signalling socket dropped and re-dialled, the camera
    /// stopped, and the call stayed up.
    ///
    /// They are all logged here because of the run that did not: with a CallKit call up,
    /// locking ended the call and delivered **none** of these first. That silence is the
    /// whole difference between "the system told us we were losing the foreground" and
    /// "the system took the call away while it still considered this app frontmost".
    private func wireDeviceLock() {
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("resigning active (lock, or a system interruption)") }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("entered the background") }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("returning to the foreground") }
        }
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("device locked") }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification,
                           object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.logLifecycle("device unlocked") }
        }
    }

    /// A short name for the phase, for a log line.
    private var phaseLabel: String {
        switch phase {
        case .loading: return "loading"
        case .needsLogin: return "needsLogin"
        case .ready: return "ready"
        case .outgoing: return "outgoing"
        case .ringing: return "ringing"
        case .inCall: return "inCall"
        case .failed: return "failed"
        }
    }

    private func logLifecycle(_ event: String) {
        let audio = AVAudioSession.sharedInstance()
        log("\(event) — phase=\(phaseLabel) socketOpen=\(signal.isSocketOpen) pipArmed=\(pip.isArmed) "
            + "category=\(audio.category.rawValue) mode=\(audio.mode.rawValue) "
            + "silenced=\(audio.secondaryAudioShouldBeSilencedHint) otherAudio=\(audio.isOtherAudioPlaying)")
    }

    private func reportCameraToRoom() {
        // Only while there is a call to report it to.
        //
        // The guard used to be the signalling peer id, which outlives the call: `disconnect`
        // clears the peers and the socket but not that id, so the next time the app came
        // forward — which ending a call causes, because CallKit takes the app out of the
        // foreground as its own UI takes over — a camera was started again for a call that
        // was already over. The indicator stayed on because the camera genuinely was on.
        // Measured 2026-09-21, on a call ended from the phone.
        guard phase.call != nil else { return }
        guard !signal.myPeerId.isEmpty else { return }
        let appIsInFront = UIApplication.shared.applicationState == .active
        // A video call that is in PiP keeps transmitting: the window exists to keep the
        // call on screen, and taking the camera away there would make it a different call.
        // A call with no window (audio only, or PiP unavailable) falls back to audio, and
        // the far end is told so it does not sit on a frozen frame.
        let keepsCamera = appIsInFront || pip.isArmed
        signal.setVideoEnabled(keepsCamera && isCameraEnabled)
        // The window is not dismissed for us when the call screen comes back, and leaving
        // it up would draw the same call twice. The arrangement stays armed, so the next
        // trip to the background opens it again.
        if appIsInFront { pip.closeWindow() }
    }

    /// The in-call screen's remote tile, which the PiP window grows out of.
    func noteRemoteTileView(_ view: UIView) {
        pipSourceView = view
        armPiP()
    }

    private func armPiP() {
        guard let view = pipSourceView, let track = signal.remoteVideo.values.first else { return }
        // The capture session has to opt in before PiP needs it, or minimising the call
        // takes the camera away and the call silently becomes audio-only.
        log(media.enableMultitaskingCamera())
        pip.arm(track: track, sourceView: view)
    }

    // MARK: - The family network

    /// Follows the embedded node, and mirrors it for the screens.
    private func wireTailnet() {
        node.addLogConsumer { [weak self] line in self?.log("tailnet: \(line)") }
        node.$state
            .sink { [weak self] state in self?.tailnetState = state }
            .store(in: &cancellables)
        node.$loginURL
            .sink { [weak self] url in
                guard let self else { return }
                self.tailnetLoginURL = url
                // Waiting for a human is a state to show rather than a slow load: nothing
                // below can be attempted until someone authorises this device, so a screen
                // that says "connecting" would be lying about what it is waiting for.
                if url != nil, self.phase == .loading { self.phase = .needsLogin }
            }
            .store(in: &cancellables)
    }

    /// Re-checks the carrier whenever the app comes forward.
    ///
    /// The cached loopback cannot be trusted after a suspension. Measured once: a node came
    /// back `Running` with an address that no longer answered, and an identical run the next
    /// day did not reproduce it. So the failure is intermittent, the clock predicts nothing,
    /// and the app verifies rather than assumes. A rebuild means a *new* address, which
    /// everything holding the old one has to be told about.
    private func wireTailnetLifecycle() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // A real user does not tap a button after switching back to the app.
            MainActor.assumeIsolated { Task { await self?.reverifyCarrier() } }
        }
    }

    /// Verifies the carrier, rebuilds the node if it stopped answering, and re-dials what
    /// the rebuild invalidated.
    private func reverifyCarrier() async {
        // Nothing to verify before the first attach: `load()` builds the carrier from
        // scratch, and a second bring-up racing it is exactly what `start()` exists to
        // prevent.
        guard TailnetNode.isEnabled, carrier != nil, node.state.isRunning else { return }
        guard await node.verifyOrRebuild(reason: "the app came forward") else { return }

        log("the network was rebuilt — re-dialling through the new carrier")
        guard let transport = try? await node.attach() else { return }
        hand(transport)

        // The event stream was holding a socket on the old loopback, so it is restarted
        // rather than left to notice. The signalling socket is re-dialled only when it is
        // actually closed: a live call must not be torn down on a hunch.
        if eventsTask != nil { startEvents() }
        if let call = phase.call, !signal.isSocketOpen { await resume(call) }
    }

    /// How this app is reaching the family network, as one line for the screen.
    ///
    /// Shown rather than only logged, because "which route is this actually using" has cost
    /// this project more measurements than any other question: the system Tailscale app is
    /// still installed on these phones, so a working connection proves a working route, not
    /// which one. The label is the carrier's own, so a node-carried session and a direct one
    /// cannot be confused on screen.
    var tailnetRoute: String {
        guard let carrier else {
            switch tailnetState {
            case .idle: return "Network: not started"
            case .starting: return "Network: starting"
            case .running: return "Network: up, no carrier yet"
            case .failed(let reason): return "Network: \(reason)"
            }
        }
        return "Network: \(carrier.label)"
    }

    /// Points both clients at a carrier.
    private func hand(_ transport: CallTransport) {
        carrier = transport
        client.transport = transport
        signal.transport = transport
    }

    /// The carrier everything in this app dials through.
    ///
    /// The node is the route a **private deployment** needs, not a thing this app does:
    /// Family Call over a tailnet answers through Serve and nowhere else, so a client
    /// without a node cannot reach it — while a server at a hostname has no network to
    /// carry and is reached the ordinary way. Which of those this device is in comes from
    /// `ConnectionMode`, and `TailnetNode.isEnabled` is where the two questions meet. A
    /// run that took one route while the screen said the other is the failure this project
    /// keeps finding, which is why each route says out loud that it is the one being taken.
    private func attachTransport() async throws -> CallTransport {
        guard TailnetNode.isEnabled else {
            // Changing the mode does not restart the app, so a node left over from the
            // private mode is still up and still logging. Nothing else will close it — this
            // is the only place that decides the route — so it goes down here rather than
            // being left as a second network this app is no longer supposed to have.
            if node.state != .idle {
                log("the mode is not a private network — closing the node")
                await node.stop()
            }
            log("dialling direct — \(AppSettings.connectionMode?.title ?? "no connection mode")")
            return .direct
        }
        let transport = try await node.attach()
        log("carried by the embedded node — \(transport.label)")
        return transport
    }

    // MARK: - CallKit wiring

    private func wireCallKit() {
        callKit.onLog = { [weak self] line in self?.log("callkit: \(line)") }
        callKit.onStart = { [weak self] callID, handle, video in
            guard let self else { return }
            self.isOutgoingCall = true
            self.callKitCallID = callID
            Task { await self.createCall(toContactID: handle, video: video) }
        }
        callKit.onAnswer = { [weak self] _ in
            self?.log("CallKit answered")
            Task { await self?.accept() }
        }
        callKit.onEnd = { [weak self] _ in
            guard let self else { return }
            // The state at this moment is the whole diagnosis: an end that arrives
            // while the app is alive and the socket is open came from the system, and
            // nothing else in the log says so.
            self.log("CallKit ended the call — phase=\(self.phaseLabel) socketOpen=\(self.signal.isSocketOpen) pipArmed=\(self.pip.isArmed)")
            Task { await self.endFromCallKit() }
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
            // Applied here rather than at connect time, because the session is only
            // active now and CallKit owns the route from this point.
            self.log(self.media.setSpeaker(self.isSpeakerOn))
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

    /// How many times a load is tried before anything is said about failing.
    ///
    /// One attempt is not a verdict. A phone waking up, a network still coming up, and a
    /// request this app itself replaced all look like failure to a single try — and putting
    /// a screen up for them asks someone to solve a problem that is already solving itself.
    /// Three tries over about eight seconds covers what resolves on its own; the screen
    /// afterwards covers what does not, and now carries a way into Settings besides.
    private static let loadAttempts = 3
    private static let loadRetryDelay = Duration.seconds(4)

    func load() async {
        phase = .loading
        notice = nil
        eventsDown = false
        eventsTask?.cancel()

        var lastReason = "The service did not answer."
        for attempt in 1...Self.loadAttempts {
            switch await attemptLoad() {
            case .settled, .cancelled:
                // Done — or no longer this load's business. Whatever cancelled it owns the
                // state now, and a cancelled request is not a service that cannot be
                // reached: reporting it as one is how a pull-to-refresh came to show
                // "Can't reach the service: cancelled" before the refresh had finished.
                return
            case .retry(let reason):
                lastReason = reason
            }

            guard attempt < Self.loadAttempts else { break }
            log("load attempt \(attempt) of \(Self.loadAttempts) did not get through — retrying")
            // A sleep that is cancelled throws, and that is the signal to stop quietly
            // rather than to say anything.
            if (try? await Task.sleep(for: Self.loadRetryDelay)) == nil { return }
        }

        phase = .failed(lastReason)
    }

    /// A load the person asked for, from the screen they asked it on.
    ///
    /// Deliberately not `load()`. That one puts the app into the connecting state, which
    /// replaces the view the pull came from — taking the refresh spinner's owner with it and
    /// cancelling the task doing the work, so the spinner had nothing left that could end it.
    /// The screen it replaced had already loaded the contacts the pull was meant to refresh.
    /// Measured 2026-09-21, on the first public deployment, by pulling down.
    ///
    /// A refusal still replaces everything: that is a different device or a different
    /// address, and it needs the screen that says so. Anything else is reported where the
    /// person already is — the list stays, and the connection is called out for what it is,
    /// the same way a dropped event stream is.
    func refresh() async {
        switch await attemptLoad() {
        case .settled, .cancelled:
            return
        case .retry:
            eventsDown = true
        }
    }

    /// What one attempt did, and whether another is worth making.
    private enum LoadOutcome {
        case settled
        /// Replaced or torn down: neither a success nor a failure, and not reported as one.
        case cancelled
        /// A reason that may not still be true in a moment.
        case retry(String)
    }

    private func attemptLoad() async -> LoadOutcome {
        // The family network comes first, because everything below it is tailnet-only and
        // the carrier is now the app's own node rather than another app's tunnel.
        do {
            hand(try await attachTransport())
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            log("the network is not carrying anything: \(error.localizedDescription)")
            // Waiting to be authorised is not a failure — it is a first run, and the screen
            // for it is the login page. A node that is up but carries nothing is a failure,
            // and `wireTailnet` has already set `.needsLogin` when a URL exists.
            let waiting = tailnetLoginURL != nil && !node.state.isRunning
            if waiting {
                phase = .needsLogin
                return .settled
            }
            return .retry("The network is up but not carrying anything.")
        }

        do {
            let session = try await client.checkSession()
            guard session.authenticated, session.configured else {
                // A refusal is an answer, and asking again would only get it again: what has
                // to change is the address or the device, and both live in Settings.
                phase = .failed(refusal(authenticated: session.authenticated))
                return .settled
            }

            let bootstrap = try await client.bootstrap()
            me = bootstrap.user
            contacts = bootstrap.contacts
            phase = .ready
            startEvents()

            history = (try? await client.callHistory()) ?? []

            // What the stream could not tell this app: an invitation that arrived while it
            // was closed. Same path the reconnect uses, because a call that arrived while
            // the app was shut has to ring exactly like one that arrived while the stream
            // was down.
            await adopt(bootstrap)

            return .settled
        } catch {
            if Self.isCancellation(error) { return .cancelled }
            log("load failed: \(error.localizedDescription)")
            return .retry(error.localizedDescription)
        }
    }

    /// Whether an error describes a request that was replaced rather than one that failed.
    private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// Why the service would not hear this device, in the words of the deployment it is in.
    ///
    /// The two modes refuse differently and have to say so differently. A private server
    /// reads an identity out of the tailnet and turns away one it does not know; a public
    /// one has no tailnet to read and is asking this device to prove itself instead. Telling
    /// someone on a public server that their *tailnet identity* was not recognised sends
    /// them looking for a network the app is not using, which is the assumption this change
    /// exists to remove.
    private func refusal(authenticated: Bool) -> String {
        let publicServer = AppSettings.connectionMode == .publicServer
        guard authenticated else {
            return publicServer
                ? "This server did not accept this device. If it asks devices to enrol, "
                    + "paste the enrolment code you were given in Settings."
                : "The service did not recognise this device's tailnet identity."
        }
        return publicServer
            ? "This server accepted this device, but it is not tied to anyone here yet."
            : "This tailnet identity is not enrolled with the service."
    }

    // MARK: - Inviting another device

    /// `POST /api/devices/enrollment`, for the screen that hands a second device its way in.
    ///
    /// Asked through this object rather than through a client of that screen's own, because the
    /// client here is this one and it carries the transport the node was wired to: a second client
    /// would dial the system's route while everything else went down the node's loopback, and the
    /// invitation would then fail on the phones where nothing else does.
    ///
    /// Nothing is kept. The invitation lives in the screen that asked for it, for as long as that
    /// screen does, and there is deliberately no field here to remember one in: this object
    /// survives the screen, and a code held past its visit is a code held past its use.
    func createDeviceInvitation() async throws -> DeviceInvitation {
        try await client.createDeviceInvitation()
    }

    // MARK: - Placing

    /// Whether the call in progress has pictures.
    ///
    /// A call carries its kind once it exists. Before that there is nothing to draw controls
    /// for, and video is the shape this app has always had, so that is what the absence means.
    var isVideoCall: Bool { phase.call?.isVideo ?? true }

    /// Asks CallKit to place the call; `onStart` then creates it. Nothing here touches
    /// the API, so there is no path to a ring that the system does not know about.
    ///
    /// `video` goes to CallKit as well as to the service. That is what makes the system's own
    /// call UI match the call: an audio call CallKit drew as a video call would offer the wrong
    /// controls on the lock screen, where this app has no say in what is drawn.
    func placeCall(to contact: FamilyContact, video: Bool) {
        guard phase.call == nil else { return }
        notice = nil
        _ = callKit.startOutgoing(handle: contact.id, video: video)
    }

    private func createCall(toContactID contactID: String, video: Bool) async {
        do {
            log("placing a \(video ? "video" : "audio") call to \(displayName(for: contactID))")
            let envelope = try await client.createCall(inviteeIds: [contactID], video: video)
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
        pip.disarm()
        callKitCallID = nil
        deviceCallID = nil
        isOutgoingCall = false
        isMuted = false
        isCameraEnabled = true
        isSpeakerOn = true
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
        // The invitation names the signalling host, which is exactly why the client and the
        // backend cannot disagree about it. Two things can still be wrong with the name it
        // carries: a deployment whose signalling host is not the one its invitations name
        // can override it in Settings, and an invitation naming loopback is describing the
        // server to itself, which from here would be this phone. `signallingOrigin` settles
        // the second case; the override settles the first, and beats it.
        let signallingOrigin = AppSettings.signallingOverrideURL
            ?? FamilyCallService.signallingOrigin(for: target.origin)
        signal.originOverride = signallingOrigin
        // The origin actually dialled, not the one the invitation carried. When the two
        // differ, that difference is the whole explanation for a call with no media in it,
        // and a log printing only the invitation sends the reader looking in the wrong
        // place. Measured that way, once.
        log(signallingOrigin == target.origin
            ? "room \(target.room) on \(target.origin.absoluteString)"
            : "room \(target.room) — signalling \(signallingOrigin.absoluteString),"
                + " not the invitation's \(target.origin.absoluteString)")
        signal.media = media
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
        // The far end cannot tell a disabled track from a stalled one, so the user's own
        // camera button reports itself on the same wire MiroTalk's client uses — otherwise
        // turning the camera off leaves the other side drawing its last frame.
        signal.setVideoEnabled(isCameraEnabled)
    }

    func switchCamera() {
        log(media.switchCamera())
    }

    /// Video calls default to the speaker: the earpiece is for a phone held to an ear,
    /// and this one is held in front of a face.
    func toggleSpeaker() {
        isSpeakerOn.toggle()
        log(media.setSpeaker(isSpeakerOn))
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

    /// Acts on what a bootstrap says is waiting for this person.
    ///
    /// An invitation is delivered on the event stream **exactly once**, to whoever is
    /// connected at that moment (`src/server.js:236-255`: no event ids, no replay). If the
    /// app was closed, the only surviving record is `/api/bootstrap` → `calls[]` with this
    /// reader still `invited` — which is precisely what the PWA re-reads on a cold open
    /// (`public/app.js:530-534`). Without this the app opened onto the contacts list while
    /// someone was still ringing: measured on a real call, 2026-09-19, where a notification
    /// from the PWA was the only sign the call had happened. The ring died with the miss.
    ///
    /// A call this device is already in is resumed instead, and only when this device
    /// joined it: identity here is a person, not a device, so every instance authenticating
    /// as this person sees the same active call, and joining one uninvited is how an Xcode
    /// preview ended up in a live call.
    private func adopt(_ bootstrap: FamilyBootstrap) async {
        guard phase.call == nil else { return }
        contacts = bootstrap.contacts
        if let invited = bootstrap.calls.first(where: { $0.myStatus == "invited" }) {
            log("an invitation was waiting for this device — ringing it")
            ring(invited)
        } else if let ongoing = bootstrap.ongoingCalls.first(where: {
            $0.id == deviceCallID && isMine($0) && $0.isActive
        }) {
            await resume(ongoing)
        }
    }

    /// Re-reads what the stream could not replay.
    ///
    /// An invitation that arrived while the stream was down is still ringing
    /// server-side, and `/api/bootstrap` is the only thing that can say so — the call's
    /// own event was delivered once, to nobody. Same handling as a launch that finds one,
    /// because the two are the same situation seen from different moments.
    private func refreshState() async {
        guard phase.call == nil else { return }
        do {
            let bootstrap = try await client.bootstrap()
            log("re-read state: \(bootstrap.calls.count) open call(s)")
            await adopt(bootstrap)
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
        return contacts.first { $0.id == userId }?.displayName ?? "Unknown caller"
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
