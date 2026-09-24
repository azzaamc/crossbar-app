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
    /// The one session this process has.
    ///
    /// Shared rather than owned by a screen, because two things need it now and neither can
    /// outrank the other: the root view, which is this session's screen, and the app delegate,
    /// which iOS tells about a call **before any screen exists** — a VoIP push can launch this
    /// app while it is closed and locked, and the report to CallKit has to come from the object
    /// that owns the CallKit provider. One session per process was always the arrangement — it
    /// owns the provider, the media engine and the network, none of which can be had twice —
    /// and this is what makes it reachable rather than merely true.
    static let shared = CallSession()

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

    /// Whether anybody on this call has sent video, mirrored from the signalling client.
    ///
    /// The call screen is one of two layouts depending on whether there is a picture, so it has
    /// to be able to observe this — and it cannot read it through `signal`, because a nested
    /// `ObservableObject` does not republish. See the sink in `init()`.
    @Published private(set) var hasRemoteVideo = false
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

    /// The load in flight, so that a second caller joins it rather than starting one. See
    /// `load()` for why there are two callers at all.
    private var loadTask: Task<Void, Never>?

    /// A call the person has already answered, waiting for this session to find out which call
    /// it is. Set and consumed by `answerPending`, which explains it.
    private var pendingAnswer: UUID?

    /// The call the most recent VoIP push named.
    ///
    /// Kept because a push is the only thing that says **which** call is being placed to this
    /// device, and the service answers with everything that is open rather than with that one:
    /// `/api/bootstrap` lists every call this person has not answered yet, and an invitation
    /// left over from earlier still reads `invited`. Ringing is then a choice between them, and
    /// the choice matters — CallKit was told the pushed call's id, so ringing a different call
    /// shows the phone a call it cannot answer while the one being made is not on screen at all.
    /// See `adopt`, which uses this to pick the pushed call out of the list.
    private var pushedCallID: UUID?

    /// The Picture-in-Picture window, armed while a call has video worth showing.
    let pip = CallPiPController()
    private var pipSourceView: UIView?
    private var cancellables = Set<AnyCancellable>()

    /// The two taps a call earns, for the two moments only this session knows about.
    private let haptics = CallHaptics()

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
                guard let self else { return }
                // Mirrored for the call screen, which is a different layout depending on
                // whether there is a picture — and a nested `ObservableObject` does not
                // republish, so a view reading `signal` through this session would never learn
                // that one had arrived. The same reason `tailnetState` is mirrored.
                self.hasRemoteVideo = !tracks.isEmpty
                guard !tracks.isEmpty else { return }
                self.armPiP()
            }
            .store(in: &cancellables)

        // The haptics for a call this device joins and a call it was in that has finished.
        //
        // Observed here, in the session, rather than by a view through `onChange`: these are
        // moments of the *call*, not of a screen. A view is on screen for a fraction of a call's
        // life — the person answering from the lock screen is looking at none of this app's
        // views at the moment the call connects, and the call screen has gone by the time the
        // end of it is worth saying — while this subscription lives exactly as long as the
        // session does. The session is also the only thing that knows the difference between a
        // call that connected and one that was declined, cancelled or failed, which is exactly
        // the difference these two taps are for.
        //
        // The one bit watched is `isInJoinedCall`, not the phase's own idea of a call: see that
        // property for the case where the two differ. Reduced to a bit before it is compared, so
        // that the repeated `.inCall` assignments arriving with every status update are not
        // events; `dropFirst` discards the state this subscription starts in, which is the
        // `.loading` phase — not a call ending, and not a join.
        $phase
            .map { [weak self] _ in self?.isInJoinedCall ?? false }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] joined in
                guard let self else { return }
                if joined {
                    self.haptics.joined()
                } else {
                    self.haptics.left()
                }
            }
            .store(in: &cancellables)
    }

    /// Whether the phase is a call **this device** has joined.
    ///
    /// Not the same question as `Self.isInCall(phase)`, and the difference is a real state
    /// rather than a hypothetical one. A person may have more than one device on their account,
    /// and a call answered on one of them is marked active for all of them: the `.callStatus`
    /// event reaches this device while it is still ringing, and the session moves to `.inCall`
    /// for a call this device has no media in — the same gap `deviceCallID` exists to keep
    /// `adopt` from rejoining through. A tap for that would be marking a join that did not
    /// happen, on a phone whose screen is the only place the call exists. `deviceCallID` is the
    /// call this device actually joined, so where it does not name the call in the phase, this
    /// session is showing a call it is not in, and a call that is not in it cannot connect or
    /// end.
    private var isInJoinedCall: Bool {
        guard case .inCall(let call) = phase else { return false }
        return call.id == deviceCallID
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
        callKit.onAnswer = { [weak self] callID in
            guard let self else { return }
            self.log("CallKit answered")
            // Handed to the pending-answer path rather than answered from here, because the
            // answer can arrive before this app knows which call it is for — see
            // `answerPending`, which is the one place that decides what an answer becomes.
            self.pendingAnswer = callID
            Task { await self.answerPending() }
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

    // MARK: - A call that arrived while the app was not running

    /// Rings for the call a VoIP push named, and gets this app into a state where it can be
    /// answered.
    ///
    /// Called **synchronously** from the push handler in `AppDelegate`, and the order inside is
    /// the whole point of the method. The report to CallKit is the first statement, with nothing
    /// in front of it: iOS 13 and later end an app that takes a VoIP push without reporting a
    /// call, and stop delivering VoIP pushes to an app that does it repeatedly. Nothing here may
    /// be awaited before that line, which is why this method takes the three values the report
    /// needs rather than reading anything for itself.
    ///
    /// Reporting is only half of answering, though. CallKit can say a call exists while this app
    /// knows nothing about it, and `accept()` responds to a `FamilyCall` — so the second half is
    /// a load, which is what asks the service which call this person is invited to. `/api/bootstrap`
    /// is the only thing that says so, and it is asked here rather than waited for: the person
    /// may answer from the lock screen before the root view has even been built, and the answer
    /// is held until the load lands. See `answerPending`.
    func reportPushedCall(callID: UUID, callerName: String, video: Bool) {
        callKit.reportIncoming(callID: callID, callerName: callerName, video: video)
        log("a VoIP push reported \(callID.uuidString.prefix(8)) from \(callerName) — video=\(video)")
        // Kept so that the load below rings *this* call rather than whichever open invitation
        // the service happens to list first. See `pushedCallID`.
        pushedCallID = callID

        // A call already in progress, or one already ringing, needs no load: whatever rings for
        // it is the event stream, which is up whenever a load has finished, and loading over a
        // live call would take its screen down and put it back.
        guard phase.call == nil else { return }

        // Nowhere to dial. A push can only have arrived for an enrolled device, but this app
        // deliberately does not decide how to reach a service on someone's behalf — the first
        // screen asks — so an app that has not been told has nothing to load against.
        guard AppSettings.connectionMode != nil else {
            log("a call was pushed to an app with no connection mode chosen — nothing to load")
            return
        }

        // A load is not free: it re-reads the state and re-dials the event stream. It is asked
        // for anyway, and it is the reason a call that arrives while the stream is down still
        // rings properly — `/api/bootstrap` is the only thing that knows about a call whose
        // event was delivered once, to nobody.
        Task { await load() }
    }

    /// Files this device's VoIP push token with the service, which is how a call reaches a phone
    /// whose app is closed. PushKit mints it, and a call this device has to report arrives on it.
    func uploadVoIPPushToken(_ token: String) async {
        await uploadPushToken(token, kind: "voip")
    }

    /// Files this device's **alert** push token with the service, which is how a missed call
    /// reaches it.
    ///
    /// A different token, from a different registry, filed under a different word, and the
    /// difference is the whole point of having two. The VoIP token rings this phone: what arrives
    /// on it is a call being placed to this device, and iOS ends an app that takes one and
    /// reports no call. This token is APNs' ordinary one, and what arrives on it is an ordinary
    /// notification — the service's record that a call nobody answered has finished. Filed under
    /// one word, one of the two would be sent where the other is expected, and that failure
    /// looks exactly like a service that sends nothing at all.
    func uploadAlertPushToken(_ token: String) async {
        await uploadPushToken(token, kind: "alert")
    }

    /// The one upload both tokens go through, because everything about them but the word is the
    /// same.
    ///
    /// Asked through this session's client for the same reason the device invitation is: that
    /// client carries the family network's own route, and one built in the push layer would dial
    /// the system's route while everything else went down the node's. See
    /// `createDeviceInvitation`.
    ///
    /// Both registries announce their token on every launch, so nothing is retried or remembered
    /// here: a service that is unreachable when it is asked is asked again by the next launch.
    ///
    /// The device id is the service's own, issued when this device enrolled — the token is filed
    /// against the device that signed the request. A device that has not enrolled has nothing to
    /// file it under, and that is a state to write down rather than a failure to report: the
    /// thing that has to happen is an enrolment, not another try.
    private func uploadPushToken(_ token: String, kind: String) async {
        guard let deviceId = DeviceAuth.shared.deviceId else {
            log("a \(kind) push token arrived before this device is enrolled — nothing to file it under")
            return
        }

        do {
            try await client.uploadPushToken(
                deviceId: deviceId,
                token: token,
                environment: PushEnvironment.current,
                kind: kind
            )
        } catch {
            log("could not file this device's VoIP token: \(error.localizedDescription)")
        }
    }

    /// What the person's answer becomes, once and in one place.
    ///
    /// CallKit's answer button is live from the moment a call is on screen, and on the path this
    /// arrangement exists for the call is on screen before this app has asked the service
    /// anything: the push reports it, and the load that names it is still running. So an answer
    /// can genuinely arrive first, and dropping it is not an option — the person has answered,
    /// and the far end would ring on while the system showed a connected call. It is held while
    /// a load is in flight, and performed at the end of that load, which is where `load()` calls
    /// this method.
    ///
    /// The call is matched by identity rather than assumed to be the one this device happens to
    /// be invited to. The answer names the call the *system* showed, and accepting a different
    /// call would put this phone into a call nobody answered for. When what was answered is not
    /// a call this device can join, it is ended — a call with an answer behind it and no media
    /// in front of it is worse than one that never rang, because the caller is told they were
    /// answered.
    private func answerPending() async {
        guard let answered = pendingAnswer else { return }

        if let running = loadTask, !running.isCancelled {
            log("the answer is waiting for the load in flight — it will be performed when that lands")
            return
        }

        pendingAnswer = nil
        guard let call = phase.call, UUID(uuidString: call.id) == answered else {
            log("a call was answered that this device has no call for — ending it")
            callKit.end(callID: answered)
            return
        }

        log("performing the answer that arrived before the call was known")
        await accept()
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

    /// Asks for a load, joining one that is already running.
    ///
    /// There are two callers now and they are not in a queue: the root view asks when its screen
    /// comes up, and the push path asks when a call arrives — which is usually while that screen
    /// is still being built. A second load over the first would be a second `/api/bootstrap`, a
    /// second event stream and a second report of the same invitation, so the second caller
    /// waits for the first rather than duplicating it.
    ///
    /// A load that has been **cancelled** is not joined, and that is why the running load is
    /// held as a task rather than as a boolean: the root view's `.task(id:)` is cancelled when
    /// the connection mode changes, and the load taken out for the mode that was replaced must
    /// not be the load the new mode is given. Cancelling the caller cancels the work it started,
    /// which is what the handler below does — a task started here does not inherit cancellation
    /// from whoever is awaiting it.
    func load() async {
        if let running = loadTask, !running.isCancelled {
            log("a load is already running — joining it rather than starting a second")
            await running.value
            return
        }

        let task = Task { await self.runLoad() }
        loadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        // Only if it is still the current one: a load that was replaced has already been
        // overtaken, and clearing the newer task here would lose track of it.
        if loadTask == task { loadTask = nil }

        // A load that was replaced is not an end, and the answer belongs to the load that
        // replaced it. Every way a load *can* end arrives here, which is why this is the one
        // place that asks what an answer that arrived too early has become.
        guard !task.isCancelled else { return }
        await answerPending()
    }

    /// One load's worth of work, retries included.
    private func runLoad() async {
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
            // Before the phase, because the phase is what says this device is in the call, and
            // whatever reads that — the haptics in `init()`, the screen — reads it the moment it
            // is published. `deviceCallID` is this session's own record of the call this device
            // joined, and a phase that arrived before it would be claiming a join for a call the
            // app had not written down yet. See `isInJoinedCall`.
            deviceCallID = envelope.call.id
            phase = .inCall(envelope.call)
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
        // An answer that was being held for a call that has just been ended is not an answer to
        // anything any more — the call it named is over, and performing it later would join a
        // different call under the same name. See `answerPending`. The pushed call goes with it:
        // it is what the next ring would be matched against, and a call that is over must not be
        // preferred over the next one to arrive.
        pendingAnswer = nil
        pushedCallID = nil
        if case .failed = phase { return }
        phase = .ready
    }

    /// Rejoins a call that is already active. `/join` is the only route that accepts a
    /// participant into an active call, and it also marks `joined_at` server-side.
    private func resume(_ call: FamilyCall) async {
        do {
            log("rejoining an active call")
            let envelope = try await client.join(callId: call.id)
            // Written down before the phase, for the reason `accept()` gives: the phase is the
            // claim that this device is in the call, and `deviceCallID` is the record of it.
            deviceCallID = envelope.call.id
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

        // The call's kind decides whether the camera runs. Until now it decided nothing: every
        // call started capture, so an audio call turned the camera on, drew this person their
        // own face, and offered a video track nobody had asked for.
        //
        // Capture is the whole of it, and the reason switching to video mid-call needs no
        // renegotiation. The peer connection is built with the video track either way — the
        // track exists from `CallMediaSource.init`, not from capture — so the m-lines are the
        // same for both kinds of call and the camera is on exactly when capture is running.
        // Turning it on later is one `startCapture`, and the far end's own camera button
        // works the same way.
        isCameraEnabled = phase.call?.isVideo ?? true
        media.videoTrack.isEnabled = isCameraEnabled
        if isCameraEnabled {
            log(media.startCapture())
        } else {
            media.stopCapture()
            log("an audio call — the camera is not started, and the video track carries nothing")
        }

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
        // The call a push named is taken first when it is in the list. The list holds every call
        // this person has not answered — an invitation left over from earlier still reads
        // `invited` — and ringing the wrong one puts a call on the system UI that cannot be
        // answered, because CallKit was told the id of the other. Without a push there is
        // nothing to prefer and the first invitation stands, as it always has. See `pushedCallID`.
        let pushed = pushedCallID.flatMap { id in
            bootstrap.calls.first { $0.myStatus == "invited" && UUID(uuidString: $0.id) == id }
        }
        if let invited = pushed ?? bootstrap.calls.first(where: { $0.myStatus == "invited" }) {
            if pushed == nil, let pushedCallID {
                log("the call the push named (\(pushedCallID.uuidString.prefix(8))) is not open on "
                    + "this device — ringing the first invitation instead")
            }
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
            // Handed over rather than reported: a call that arrived by push has already been
            // reported by the app delegate, and `CallKitController` says so instead of asking
            // the system twice for the same call.
            log("handing the call to CallKit")
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

    /// A line into this app's own log, which is the instrument this project measures with.
    ///
    /// Internal rather than private because the push path writes here too, and push handling
    /// lives in `AppDelegate`: a VoIP push that left no trace would be indistinguishable from
    /// one that never arrived, which is already the hardest failure on this project to see.
    /// Nothing is logged before the session exists — the first write truncates the file, as it
    /// always has — so a launch that a push caused starts its log with what the push did.
    func log(_ line: String) {
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

/// The two taps a call earns: one for joining it, and one for it being over.
///
/// Both are played for a moment rather than for a screen, so neither is kept. A
/// `UIFeedbackGenerator` that has been prepared holds the Taptic Engine awake — that is what
/// preparing it *means* — and two moments that can be hours apart are no reason to keep it
/// running. Each method below makes the generator it needs, prepares it, plays it, and lets it
/// go at the end of the call it was made in, which is the only way to release one: the class has
/// no `unprepare`, and a generator alive is a generator the engine is warm for.
@MainActor
final class CallHaptics {
    /// A call this device has joined — and that is exactly when it is played.
    ///
    /// A tap when the phone merely rings, or when an offer is sent, would be saying something
    /// that has not happened; the caller could still give up, the far end could still decline.
    /// So this is called from the session's own transition into a call, which is where an answer
    /// has been accepted and this device is in the room, and nowhere else. See the subscription
    /// in `CallSession.init()`.
    ///
    /// An impact rather than a notification: joining is a thing happening under the finger rather
    /// than an outcome being judged, and `.medium` is the weight behind a state the person asked
    /// for and has now got.
    func joined() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
    }

    /// A call this device was in that has finished.
    ///
    /// The `.success` pattern is the quiet end of it: nothing failed and nothing is being
    /// reported, the call simply closed, and the tap is there for a moment at which the screen
    /// showing the call has already gone. Nothing is played for a call that was declined,
    /// cancelled before it connected, or refused — none of those ever reached `joined()`, and a
    /// tap there would be marking an end to something that never started.
    func left() {
        let generator = UINotificationFeedbackGenerator()
        generator.prepare()
        generator.notificationOccurred(.success)
    }
}
