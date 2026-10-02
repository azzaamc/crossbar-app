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
        /// The network is waiting to be authorised. Not a failure and not a slow
        /// load: nothing else can be attempted until a human opens the login page, so the
        /// screen has to say so. The URL itself is published separately, because it
        /// arrives while this phase is already in force.
        case needsLogin
        /// The service has not answered, and the app has stopped waiting behind a launch
        /// screen for it: the people it already has are shown while the attempts left run.
        /// Not a failure — a failure is what this becomes when they are spent — and not
        /// `.ready`, because nothing has been loaded.
        case retrying(String)
        case ready
        case outgoing(Call)
        case ringing(Call)
        case inCall(Call)
        case failed(String)

        var call: Call? {
            switch self {
            case .outgoing(let call), .ringing(let call), .inCall(let call): return call
            default: return nil
            }
        }
    }

    /// What a load found for the call a VoIP push reported.
    ///
    /// A push is reported to CallKit before anything can be asked about it — iOS ends an app that
    /// takes a VoIP push and reports nothing — so this is the first moment the service can be
    /// heard on the question of whether the call is really being placed. Three of the four answers
    /// are a call to ring, to rejoin, or to end; the fourth is no push at all.
    enum PushedArrival: Equatable {
        /// No push named a call. Whatever invitation the service lists stands, as it always has.
        case unpushed
        /// The service names the pushed call, and this device is invited to it.
        case invited(Call)
        /// The service names the pushed call and says this device is already in it.
        case ongoing(Call)
        /// The service does not name the pushed call at all. It has to be ended.
        case unknown
    }

    @Published private(set) var phase: Phase = .loading
    @Published private(set) var me: Person?
    @Published private(set) var contacts: [Contact] = []

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

    /// Where the server says it is, when that is not where this device was set up for.
    ///
    /// Non-nil means the deployment moved under this device: an administrator switched the
    /// server between its private and public configurations, and the app is still dialling the
    /// one it was enrolled against. It carries the *server's* mode rather than a flag because
    /// what the person has to do about it depends on where the server went — a private network
    /// needs Tailscale, and either one needs the address that only a new code carries.
    @Published private(set) var serverMovedTo: ConnectionMode?

    /// Set when this device has been taken back to nothing and has to be set up again.
    ///
    /// The app root shows onboarding for it, which is the only screen that can do anything
    /// about it. It is a published flag rather than a read of `AppSettings.connectionMode`,
    /// because the setting is not observable and the state is already seeded from it — the
    /// value read at launch would go on saying this device is set up long after it is not.
    @Published private(set) var needsSetup = false
    @Published private(set) var isSpeakerOn = true
    /// Surfaced rather than swallowed. A socket that has quietly died looks exactly
    /// like a quiet one, and this project has already lost a measurement to that.
    @Published private(set) var eventsDown = false

    /// The same fact about the **signalling socket**, which is what a call's media is carried
    /// by. Surfaced for the same reason as `eventsDown` and for one more: the socket is what a
    /// live call is running on, and a socket that has dropped leaves the last frame it received
    /// drawn on the screen — so without this a call with nothing behind it looks exactly like a
    /// working one. Mirrored from `signal.isReconnecting` rather than read through `signal`,
    /// because a nested `ObservableObject` does not republish, the same reason `hasRemoteVideo`
    /// is mirrored.
    @Published private(set) var signalDown = false

    /// Whether anything the call is running on is being re-established: the event stream, the
    /// signalling socket, or both.
    ///
    /// What the call screen reads, so one indicator covers both connections a call depends on —
    /// and a person is never shown a call that looks connected while it carries nothing.
    var isReconnecting: Bool { eventsDown || signalDown }

    @Published private(set) var notice: String?

    let media = CallMediaSource()
    let signal = MiroTalkSignalClient(label: "call")

    private let client = ServiceClient()
    private let callKit = CallKitController()

    /// The network this app carries with it.
    ///
    /// Shared rather than owned: a node holds a device identity and a state directory, so
    /// one per process is the only arrangement that does not leave two of them fighting
    /// over both. The DEBUG instruments use this same object, which is also why it is not
    /// created here.
    let node = TailnetNode.shared

    /// Where the carrier is, once a node has produced one. Held because a rebuild makes a
    /// new one, and everything dialling the old address has to be re-dialled.
    private var carrier: CallTransport?

    /// The network's state, mirrored for the views.
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
    /// See `adopt` and `arrival`, which use this to pick the pushed call out of the list — and to
    /// end the ring when the service's list does not have it at all (SEC-RELAY-05).
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
    /// The service's identity is a person, not a device: `/api/bootstrap` answers "am I
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

        // The signalling socket's own recovery, mirrored so the call screen can say so, and
        // finished here: the client re-dials on a backoff by itself, but only the session can
        // end a call. A socket that never comes back is the one failure that has to be said out
        // loud rather than retried quietly — the call is over, and a device left in `phase=inCall`
        // with no peers can never be told anything again. See `giveUpOnCall`.
        signal.$isReconnecting
            .sink { [weak self] reconnecting in self?.signalDown = reconnecting }
            .store(in: &cancellables)
        signal.onUnrecoverable = { [weak self] in
            Task { await self?.giveUpOnCall() }
        }

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

        // Said once, at launch, when there is nothing to dial. An unconfigured device shows
        // the setup screen and makes no request at all, and a reason that appeared only at the
        // moment of a failing request would leave that case — nothing attempted — looking
        // exactly like a device that is quietly working. The words name the state rather than
        // a fault, because it is what the setup screen is for.
        if !ServiceAddress.isConfigured {
            log("no service address is set — this device has not been told which Crossbar it "
                + "belongs to, so nothing is dialled until an enrollment code is pasted")
        }
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

    /// Whether the app is still on its way to a first answer: the phases a load passes through
    /// before it has either settled or failed.
    private var isLoading: Bool {
        switch phase {
        case .loading, .retrying: return true
        default: return false
        }
    }

    /// A short name for the phase, for a log line.
    private var phaseLabel: String {
        switch phase {
        case .loading: return "loading"
        case .needsLogin: return "needsLogin"
        case .retrying: return "retrying"
        case .ready: return "ready"
        case .outgoing: return "outgoing"
        case .ringing: return "ringing"
        case .inCall: return "inCall"
        case .failed: return "failed"
        }
    }

    private func logLifecycle(_ event: String) {
        let audio = AVAudioSession.sharedInstance()
        log("\(event) — phase=\(phaseLabel) socketOpen=\(signal.isSocketOpen) "
            + "signalDown=\(signalDown) pipArmed=\(pip.isArmed) "
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

    // MARK: - The network

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
                if url != nil, self.isLoading { self.phase = .needsLogin }
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

    /// How this app is reaching the network, as one line for the screen.
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
    /// The service over a tailnet answers through Serve and nowhere else, so a client
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

    /// Builds the route this device will dial through, for the screen that has to enrol before
    /// there is anything to load.
    ///
    /// Onboarding runs before any load, so nothing has built a carrier yet — and on a private
    /// deployment the enrollment is the *first* request that has to go through one. Built here
    /// rather than by the screen, because `attachTransport` is the only thing that chooses a
    /// route and a second chooser would be a second answer: this is that same decision, asked
    /// early. Handing it out sets the clients' transports, which is what points the enrollment
    /// at the node instead of at a route the node is not on.
    ///
    /// It returns only once the carrier has actually carried a request, so a device that has
    /// never been authorised parks here — which is the point, and why the screen shows the
    /// login page while this waits.
    func attachForSetup() async throws {
        hand(try await attachTransport())
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
        callKit.onEnd = { [weak self] endedCallID in
            guard let self else { return }
            // CallKit says *which* call ended, and it is not always ours. Asking it to end a call
            // this app is not carrying — a pushed call arriving while one is already on screen —
            // comes back through this very callback, and acting on it ended the call the person was
            // actually on: on 2026-10-02 a second ring hung up a live call and ended it on the
            // service too, from `endFromCallKit` below ending whatever `phase` held. A call this
            // device is not carrying is not this device's to tear down. `callKitCallID` is nil for
            // a call CallKit was never told about, and an end naming one of those is not ours either.
            guard endedCallID == self.callKitCallID else {
                self.log("CallKit ended \(endedCallID.uuidString.prefix(8)) — not this device's "
                         + "call, so \(self.phaseLabel) is left alone")
                return
            }
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

    /// What a VoIP push asks of CallKit, given what this device already has on screen.
    ///
    /// Its own value rather than three branches inside `reportPushedCall`, because these three
    /// answers are the whole of what a push means once something is already being carried, and
    /// the two mistakes available here are both invisible from the outside: leaving a second call
    /// ringing that this app has no media for and no screen to answer from, and *ending* the call
    /// the person is looking at because a redelivered wake named the same call twice.
    enum PushedReportPlan: Equatable {
        /// Nothing is on screen: report the call and reconcile it with a load, as always. No end.
        case ring
        /// The push names the call already on screen — the relay replays a wake it has already
        /// sent within the day, and APNs redelivers ordinary ones. The report is still made
        /// (`CallKitController` recognises its own earlier report), and nothing else may happen:
        /// an end here would take down the live ring.
        case alreadyOnScreen
        /// A different call while one is on screen. This app carries **one call at a time** — the
        /// phase holds one, and `adopt` refuses to act while it does — so the pushed call cannot
        /// be rung *and* backed. Report it, because iOS requires a report for every VoIP push and
        /// ends an app that takes one and reports nothing, and end it in the same breath: a ring
        /// whose answer could never reach anything is worse than one that never lasted, because
        /// it asks the person to answer a call with nothing behind it. The associated id is the
        /// one ended — the pushed call's, never the call on screen — and the system's own Recents
        /// is where the missed one is still recorded.
        case reportThenEnd(UUID)

        /// The calls this plan asks CallKit to end, in order.
        ///
        /// Data rather than a branch, because these are the calls the system is told to take off
        /// its screen, and that is what has to be true: exactly the pushed call on the busy path,
        /// never the call that is already there, and nothing at all for the two states where the
        /// report stands on its own. `CallKitController.end` is idempotent per call, so this list
        /// is also the count of end requests the system receives.
        var endedCalls: [UUID] {
            if case .reportThenEnd(let pushed) = self { return [pushed] }
            return []
        }

        /// Whether the load that reconciles a push with the service is asked for.
        ///
        /// False for the two states where a load would be wrong: a second wake for the call
        /// already on screen, and a call this app is ending — a load over a call in progress takes
        /// that call's screen down and puts it back.
        var reconciles: Bool { self == .ring }
    }

    /// Which of the three a push is, given the id it named and what is on screen.
    ///
    /// Pure and static, so the whole of the question is in one place. `onScreen` is the CallKit
    /// id this session has already told the system about (`callKitCallID`), and `busy` says
    /// whether the phase is carrying a call at all — the two can differ, because a call whose id
    /// is not a UUID is on screen with no CallKit id of its own, and one of those must still be
    /// treated as a call in progress.
    static func pushedReportPlan(pushed: UUID, onScreen: UUID?, busy: Bool) -> PushedReportPlan {
        if pushed == onScreen { return .alreadyOnScreen }
        return busy ? .reportThenEnd(pushed) : .ring
    }

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
    /// knows nothing about it, and `accept()` responds to a `Call` — so the second half is
    /// a load, which is what asks the service which call this person is invited to. `/api/bootstrap`
    /// is the only thing that says so, and it is asked here rather than waited for: the person
    /// may answer from the lock screen before the root view has even been built, and the answer
    /// is held until the load lands. See `answerPending`.
    ///
    /// **And only while nothing is on screen.** The report is unconditional — iOS requires one per
    /// VoIP push — but what follows it is not: see `PushedReportPlan` for the three states a push
    /// can arrive into, and for why the one that used to return here in silence left a second
    /// CallKit call ringing with nothing that could answer it.
    func reportPushedCall(callID: UUID, callerName: String, video: Bool) {
        callKit.reportIncoming(callID: callID, callerName: callerName, video: video)
        log("a VoIP push reported \(callID.uuidString.prefix(8)) from \(callerName) — video=\(video)")

        // What is left to do, which is exactly where the three states differ. The report above
        // happened whatever the answer is; the end and the load are the parts that may not.
        let plan = Self.pushedReportPlan(pushed: callID, onScreen: callKitCallID, busy: phase.call != nil)

        if !plan.endedCalls.isEmpty {
            // The end is what makes the difference between a ring somebody could answer and one
            // that only exists on the lock screen. The calls in the list are the ones the system is
            // told to take down, and on this path there is exactly one — the pushed call, never the
            // call that is on screen.
            log("a call is already on screen — ending the pushed call "
                + "\(callID.uuidString.prefix(8)) rather than leaving a second ring with nothing "
                + "able to answer it")
            for ended in plan.endedCalls { callKit.end(callID: ended) }
            return
        }

        guard plan.reconciles else {
            // Heard twice, which is ordinary rather than a fault: the relay replays a wake it has
            // already sent within the day, and APNs redelivers. Nothing to end and nothing to
            // reconcile — this ring is the call the person can see.
            log("the push names the call already on screen — nothing to reconcile")
            return
        }

        // Kept so that the load below rings *this* call rather than whichever open invitation
        // the service happens to list first. See `pushedCallID`.
        pushedCallID = callID

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

    /// Push tokens PushKit has given this app before it could file them.
    ///
    /// Held rather than dropped, because neither of the two ways an upload can fail is the
    /// token's fault and PushKit will not raise the token again until the next launch — so a
    /// token lost here is lost until then, and a phone that is merely backgrounded never gets
    /// there. Both failures are races this app loses by construction:
    ///
    ///  - **A device that enrols during the same launch** is announced before it exists, and the
    ///    upload has nowhere to put it.
    ///  - **A transport that is not up yet.** The upload is attempted the moment PushKit speaks,
    ///    which is before any load has run, so for a private deployment it goes out over the
    ///    direct route to an address that only resolves inside a network this app has not
    ///    brought up. Measured 2026-09-24: a phone enrolled at 16:19 had filed nothing by 17:31,
    ///    on a launch whose `presence_broadcast` proves the load itself was fine.
    ///
    /// Both are fixed by the same thing: keep it, and try it again — on a bounded doubling delay
    /// (`startPushTokenRetries`), and once a load has settled (`fileHeldPushTokens`), whichever
    /// comes first. Whichever of the two files it clears it from here.
    ///
    /// **Held only while the deployment's answer says another attempt is worth making.** A relay
    /// refusal that will not change — `409 token_conflict`, and only that — clears the token
    /// instead, through `PushTokenVerdict`: a phone that is offered again and again to an answer
    /// that cannot change is a retry storm, and one whose token is quietly forgotten while the
    /// relay still refuses it is a phone that never rings with nothing saying so. See
    /// `PendingPushTokens`, which is where the two are told apart, and `pushTokenRefusals`, which
    /// is where a permanent refusal is published for the screen to read.
    private var heldPushTokens = PendingPushTokens()

    /// The push token kinds the relay has refused **for good**, with its own word for why.
    ///
    /// Published state rather than a sentence in `notice`, because a refusal is a condition and
    /// not a moment. `notice` is said once about a moment and every load and refresh clears it
    /// (`runLoad`, `refresh`) — while this does not end when a load does: the relay will not take
    /// the token, `heldPushTokens` no longer holds it, and nothing asks again until this process
    /// next launches. A sentence a load can erase is a phone that cannot be rung with the UI
    /// saying nothing, which is the failure this whole token path exists to end
    /// (`docs/PUSH_RELAY_INTEGRATION.md` §5). So the screen reads *this*, every time it looks, and
    /// it stops the moment the condition does — a token for that kind filed, which is the only
    /// answer that makes the phone ringable again.
    @Published private(set) var pushTokenRefusals = PushTokenRefusals()

    /// The upload retries currently running, one per token kind.
    ///
    /// Held so that a retry can be stopped: PushKit can announce a new token while the old one is
    /// still being retried — a rotation, or a second launch — and two uploads racing is the retry
    /// storm this is bounded to avoid. A load stops them too, because `fileHeldPushTokens` does
    /// the same job on its own schedule.
    private var pushTokenRetries: [String: Task<Void, Never>] = [:]

    /// The newest token PushKit has given for each kind.
    ///
    /// The reason a retry is safe to run at all. By the time a retry goes out, the token it was
    /// started for may have been replaced, and filing a replaced token would put back on the
    /// service a token APNs no longer mints — the failure this app cannot see from the device.
    /// Checked before every attempt, not once at the start.
    private var latestPushTokens: [String: String] = [:]

    /// How many times an upload is retried on its own before it is left to the next load.
    ///
    /// Bounded, and small on purpose. Both failures it exists for are about the first seconds of
    /// a launch — no device id yet, and no carrier yet — and both are also caught by
    /// `fileHeldPushTokens` when a load settles, so this is the path that matters when the load
    /// itself is late. Beyond it an unreachable service is an unreachable service, and iOS hands
    /// this app the token again on the next launch.
    private static let pushTokenAttempts = 6

    /// The wait before attempt `attempt`, doubling from a second: 1, 2, 4, 8, 16, 32.
    ///
    /// Doubling rather than fixed, because what is being waited for is a node coming up and the
    /// requests are what a retry storm is made of. Measured 2026-09-24: a phone enrolled at 16:19
    /// had filed nothing by 17:31, on a launch whose `presence_broadcast` proves the load itself
    /// was fine — the upload went out before the node existed, and nothing ever asked again.
    private static func pushTokenBackoff(_ attempt: Int) -> Duration {
        .seconds(1 << (attempt - 1))
    }

    /// Files this device's VoIP push token with the service, which is how a call reaches a phone
    /// whose app is closed. PushKit mints it, and a call this device has to report arrives on it.
    func uploadVoIPPushToken(_ token: String) async {
        await uploadPushToken(token, kind: "voip")
    }

    /// Files whatever PushKit has given this app that could not be filed at the time.
    ///
    /// Called once a load has settled, which is the first moment both halves are true: there is a
    /// device to file against, and there is a transport that can carry the request. Nothing is
    /// cleared unless the service accepted it — a filed token, and one the relay will never take —
    /// so a retryable refusal here is retried by the next load rather than being another token
    /// this app threw away.
    private func fileHeldPushTokens() async {
        guard let deviceId = DeviceAuth.shared.deviceId, !heldPushTokens.isEmpty else { return }
        // A load is doing this job now, so the retries racing it are stopped rather than left to
        // duplicate the request — the same reason a replaced token stops the retry for it.
        for kind in heldPushTokens.kinds {
            pushTokenRetries[kind]?.cancel()
            pushTokenRetries[kind] = nil
        }
        for (kind, token) in heldPushTokens.entries {
            switch await sendPushToken(token, kind: kind, deviceId: deviceId) {
            case .filed:
                resolve(.filed, kind: kind)
                log("the \(kind) push token held from launch has been filed")

            case .permanent(let code):
                refusePushToken(code: code, kind: kind)

            case .retry(let reason):
                log("could not file the held \(kind) push token (\(reason)) — kept for the next load")
            }
        }
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
    /// client carries the network's own route, and one built in the push layer would dial
    /// the system's route while everything else went down the node's. See
    /// `createDeviceInvitation`.
    ///
    /// **An attempt, and then retries that do not hold anything up.** The first attempt happens
    /// now, on whichever route the app has at this instant — at launch that is the direct one, to
    /// an address only a node that has not been brought up can resolve. That failure is expected
    /// rather than exceptional, so it is not the end of the token: the token is held, and
    /// `startPushTokenRetries` tries it again on a doubling delay while `fileHeldPushTokens` tries
    /// it once a load has settled. Neither waits for the other, and this method returns after its
    /// own attempt — nothing here holds a launch still for a minute.
    ///
    /// The device id is the service's own, issued when this device enrolled — the token is filed
    /// against the device that signed the request. A device that has not enrolled has nothing to
    /// file it under, and that is a state to write down rather than a failure to report: the
    /// thing that has to happen is an enrollment, not another try. The load that follows the
    /// enrollment is what files the token, through `fileHeldPushTokens`.
    ///
    /// What the deployment answers decides whether there is anything left to do, and that is the
    /// half of this that used to be missing: the token is filed in two places now, and the relay
    /// is the one that rings the phone, so `PushTokenVerdict` — not `saved` — is what says a token
    /// has landed.
    private func uploadPushToken(_ token: String, kind: String) async {
        latestPushTokens[kind] = token
        // A retry for a token PushKit has just replaced is stopped rather than left to file the
        // old one after this one. `latestPushTokens` is what makes that exact even for a request
        // already in flight.
        pushTokenRetries[kind]?.cancel()
        pushTokenRetries[kind] = nil

        guard let deviceId = DeviceAuth.shared.deviceId else {
            heldPushTokens.hold(token, kind: kind)
            log("a \(kind) push token arrived before this device is enrolled — held until it is")
            return
        }

        switch await sendPushToken(token, kind: kind, deviceId: deviceId) {
        case .filed:
            resolve(.filed, kind: kind)

        case .retry(let reason):
            // Held for the same reason as above, and this is the case that actually happens: at
            // launch there is no carrier yet, so an upload attempted the moment PushKit speaks is
            // a request over the direct route to an address only a network this app has not
            // brought up can resolve. `startPushTokenRetries` and `fileHeldPushTokens` both take
            // it from here.
            heldPushTokens.hold(token, kind: kind)
            log("this device's \(kind) push token could not be filed (\(reason)) — kept for the next attempt")
            startPushTokenRetries(token: token, kind: kind, deviceId: deviceId)

        case .permanent(let code):
            refusePushToken(code: code, kind: kind)
        }
    }

    /// One attempt at filing a token, as what the service's answer means for it.
    ///
    /// A verdict rather than a throw or a boolean, because the two refusals are no longer one
    /// kind: a deployment that could not reach its relay has a token worth offering again, and one
    /// whose relay says the token belongs to somebody else does not (`PushTokenVerdict`). Nothing
    /// here logs, because the three callers write different lines around the same answer, and
    /// nothing here decides *when* to try again — that is `pushTokenBackoff`'s business.
    private func sendPushToken(_ token: String, kind: String, deviceId: String) async -> PushTokenVerdict {
        do {
            return try await client.uploadPushToken(
                deviceId: deviceId,
                token: token,
                environment: PushEnvironment.current,
                kind: kind
            ).verdict
        } catch {
            // No usable answer at all: the request never landed, the service refused it outright,
            // or its body did not decode. Retryable rather than fatal — the route's own refusals
            // (a device that is unknown, or revoked, or asking too often) are about the request or
            // about a state an operator can change, and a bounded backoff plus one attempt per
            // launch is not a storm. Permanence is the relay's to declare, in its own answer, and
            // an answer this app could not read is not it.
            return .retry(error.localizedDescription)
        }
    }

    /// Applies the deployment's verdict to the token held for `kind`.
    ///
    /// One place, because a verdict means two things at once now: what is still waiting to be
    /// filed (`heldPushTokens`) and what the relay has refused **for good**
    /// (`pushTokenRefusals`). They are told apart by how long they last — the first is cleared by
    /// the next load that settles, the second is only cleared by a token the relay takes — so
    /// nothing else in this file may write either of them.
    @discardableResult
    private func resolve(_ verdict: PushTokenVerdict, kind: String) -> Bool {
        let stillPending = heldPushTokens.resolve(verdict, kind: kind)
        pushTokenRefusals.apply(verdict, kind: kind)
        return stillPending
    }

    /// Ends the attempts for a token the relay will keep refusing, and says so.
    ///
    /// `409 token_conflict` means the relay's token row has an owner, and only that owner letting
    /// go — or the relay's operator — can free it, so another attempt asks a question whose answer
    /// cannot change. The token is dropped from the pending set rather than retried, and the
    /// condition is published rather than said once, because a phone that cannot be rung with
    /// nothing saying so is exactly the failure this path exists to end: the screen reads
    /// `pushTokenRefusals` on every appearance, and what a load clears — `notice` — is not where
    /// this lives. The next launch re-announces the token to PushKit and asks once more, which is
    /// what makes a released token become ringable again without anybody reinstalling anything.
    private func refusePushToken(code: String, kind: String) {
        resolve(.permanent(code: code), kind: kind)
        log("the relay refused this device's \(kind) push token (\(code)) — not asked again until this device is ringable")
    }

    /// Tries a token again, on a doubling delay, a bounded number of times.
    ///
    /// One task per kind, so a token that keeps failing cannot multiply into several uploads, and
    /// a wait before every attempt, so it cannot become a storm either. Nothing here blocks a
    /// launch: the first attempt has already been made and returned, and this runs beside whatever
    /// the app is doing.
    ///
    /// Each attempt is skipped unless the token is still both the newest PushKit has given and the
    /// one still waiting to be filed — so a rotation ends the old token's retries, and a load that
    /// filed it first ends them too, rather than two uploads of the same token arriving together.
    ///
    /// The token leaves the held set the moment the service's answer says to stop: filed, or
    /// refused in a way that will not change. If the attempts run out it stays held, which is the
    /// case `fileHeldPushTokens` exists for — the next load is then the next try rather than the
    /// last.
    ///
    /// The handle is deliberately not cleared from inside the task: a task that lost its token to
    /// a rotation must not clear the entry belonging to the retry that replaced it.
    private func startPushTokenRetries(token: String, kind: String, deviceId: String) {
        pushTokenRetries[kind] = Task { [weak self] in
            for attempt in 1...Self.pushTokenAttempts {
                do {
                    try await Task.sleep(for: Self.pushTokenBackoff(attempt))
                } catch {
                    // Cancelled: a newer token, or a load, has taken this over.
                    return
                }
                guard let self, self.latestPushTokens[kind] == token,
                      self.heldPushTokens[kind] == token
                else { return }
                switch await self.sendPushToken(token, kind: kind, deviceId: deviceId) {
                case .filed:
                    self.resolve(.filed, kind: kind)
                    self.log("the \(kind) push token was filed on retry \(attempt) of \(Self.pushTokenAttempts)")
                    return

                case .permanent(let code):
                    self.refusePushToken(code: code, kind: kind)
                    return

                case .retry(let reason):
                    self.log("the \(kind) push token was not filed on retry \(attempt) of "
                        + "\(Self.pushTokenAttempts): \(reason)")
                }
            }
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
    /// How many attempts are made before the app stops holding the screen. The rest are made
    /// behind the app rather than in front of it.
    private static let attemptsBeforeShowingTheApp = 2
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

            // Two attempts is as long as a launch screen is worth. Somebody who opened Crossbar
            // to ring a house is better served by their people and an honest "not connected"
            // than by a spinner that is telling them nothing — and the attempts left are still
            // made, just not in front of a blank screen.
            if attempt >= Self.attemptsBeforeShowingTheApp {
                phase = .retrying(lastReason)
                log("showing the app while it keeps trying — phase=retrying after "
                    + "\(attempt) of \(Self.loadAttempts) attempts: \(lastReason)")
            }

            guard attempt < Self.loadAttempts else { break }
            log("load attempt \(attempt) of \(Self.loadAttempts) did not get through — retrying")
            // A sleep that is cancelled throws, and that is the signal to stop quietly
            // rather than to say anything.
            if (try? await Task.sleep(for: Self.loadRetryDelay)) == nil { return }
        }

        log("the load gave up after \(Self.loadAttempts) attempts — phase=failed: \(lastReason)")
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
    ///
    /// The notice goes first, and that is the one thing this shares with `runLoad`: a notice
    /// belongs to the load that published it, and a load the person asked for — this one — must
    /// not leave the previous load's sentence on the screen as though this one had just said it.
    /// A pull-to-refresh used to clear nothing at all, which is where the owner's report of
    /// 2026-09-26 lands: after a move, a pull-to-refresh still showed the move's notice, and the
    /// only thing that took it down was the next full load.
    func refresh() async {
        notice = nil
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

    /// What one pass at the service did, and where the fault is if it did not finish.
    ///
    /// The four are not degrees of one failure. Two of them are about the **address** — it said
    /// nothing, or it said no — and those are what a move this device followed has to be judged
    /// by, because an address that will not take this device may be the wrong address rather than
    /// the wrong device. The other two are about this device's own data, and neither implicates
    /// the address.
    private enum ReadOutcome {
        /// The load finished, or was replaced. Either way this attempt is over.
        case answered(LoadOutcome)
        /// Nothing came back: no reply, or the request never completed.
        case unanswered(String)
        /// The address answered, and would not take this device.
        case refused(String)
        /// The address took this device; what went wrong came afterwards.
        case failed(String)
    }

    private func attemptLoad() async -> LoadOutcome {
        // The network comes first, because everything below it is tailnet-only and
        // the carrier is now the app's own node rather than another app's tunnel.
        if let blocked = await attachRoute() { return blocked }

        // Still nothing authenticated: a server that has moved under this device says where it
        // went, and the address this device already holds is the only thing that can be asked —
        // which is why the ask belongs here, before `/api/session` and before any request
        // carries this device's identity. See `followMovedServer`.
        if await followMovedServer() {
            // The route follows the mode, and the mode has just changed under this load, so the
            // carrier attached a moment ago belongs to the deployment being left. Asked again
            // rather than kept: `attachTransport` is the only thing that chooses a route, and a
            // node carried for the old mode is a second network on a device that no longer wants
            // one.
            if let blocked = await attachRoute() { return blocked }
        }

        switch await readService() {
        case .answered(let outcome):
            return outcome

        case .failed(let reason):
            // The service took this device, and what went wrong came afterwards. That is this
            // device's own data rather than where it is dialling, so the address does not change
            // because of it and another go from the same one is the right answer.
            return .retry(reason)

        case .unanswered(let reason):
            // Nothing came back at all. This is the shape a front door that is not up yet arrives
            // as — the connection is accepted and nothing is ever said — and it is one of the two
            // ways a move this device followed fails.
            guard let home = returnHome(because: reason) else { return .retry(reason) }
            return await finishAt(home)

        case .refused(let reason):
            // An answer, and one that says this address will not take this device. Asking the same
            // address again would only get it again, so unless there is somewhere to come back to
            // — which there is only for a move this device followed — this is the end of the load:
            // what has to change is the address or the device, and both live in Settings.
            guard let home = returnHome(because: reason) else {
                phase = .failed(refusal(authenticated: false))
                return .settled
            }
            return await finishAt(home)
        }
    }

    /// Finishes this attempt at the address this device came home to.
    ///
    /// Split out of `attemptLoad` for the reason `attachRoute` is: one attempt may make two passes
    /// at the service. The second pass exists only for a move that was followed and then did not
    /// work, and it is made here rather than left to the retry loop so that coming back costs this
    /// attempt instead of the two after it — the loop's attempts are for a service that is still
    /// coming up, and a move to an address that answers with nothing is not that. Both ways an
    /// address can fail arrive here, because from the device's side they are one fact.
    private func finishAt(_ home: String) async -> LoadOutcome {
        // The route came home with the address, so it is taken again before anything is dialled:
        // `attachTransport` is the only thing that chooses one, and the mode a move changed is half
        // of that choice.
        if let blocked = await attachRoute() { return blocked }
        switch await readService() {
        case .answered(.settled):
            log("the load finished at \(home) after all — this device is where it was")
            return .settled
        case .answered(let outcome):
            return outcome
        case .failed(let reason), .unanswered(let reason):
            return .retry(reason)
        case .refused:
            // Home will not take this device either, and that is not about a move: it is this
            // device and the service it was enrolled with, which is the answer the failure screen
            // has always given.
            phase = .failed(refusal(authenticated: false))
            return .settled
        }
    }

    /// Comes back to the address this device was dialling before it followed a move.
    ///
    /// Answers where it went, or `nil` when no move is outstanding and there is therefore nothing
    /// to undo — the caller then answers the failure the way it always has.
    ///
    /// The way home is read back out of the settings rather than carried in memory, so it is still
    /// there for the cases that outlive the load which wrote it: a device killed between adopting
    /// an address and loading it, and a load cancelled in between by a mode change, both come back
    /// here on their next attempt instead of staying on the address they followed.
    private func returnHome(because reason: String) -> String? {
        guard let home = AppSettings.previousServiceAddress else { return nil }
        let lost = AppSettings.serviceAddress ?? "the address it followed"

        // What the device is coming home *from* is kept, in the same canonical spelling the move
        // comparison reads, so the next load recognises the address the deployment names as one
        // this device has already tried rather than hearing about it for the first time. Cleared
        // by the ways out of it — a different address named, the move landing, a device set up
        // again — never by simply having failed once.
        AppSettings.abandonedServiceAddress = AppSettings.serviceAddress
        AppSettings.serviceAddress = home
        // The mode comes home with the address: it was changed by the same answer, and the route
        // everything dials is chosen from it.
        AppSettings.connectionMode = AppSettings.previousConnectionMode
        AppSettings.forgetPreviousAddress()

        // What the person is told, and why in these words: this app did what the deployment asked
        // of it and the address it was sent to did not work, so the failure belongs to the move
        // rather than to them, and nothing about it is theirs to fix.
        notice = "Your Crossbar appeared to have moved, so this app followed it — but the new "
            + "address did not work, and this app has come back to the one it was using. "
            + "Nothing here needs doing."
        log("\(lost) did not work (\(reason)) — back to \(home), which is where this device "
            + "came from")
        return home
    }

    /// Forgets the address this device came from, now that the address it followed has answered
    /// for it.
    ///
    /// The other half of `returnHome`, and the reason following a move is safe to do at all: the
    /// way home is kept for exactly as long as it might be needed, which is until the service at
    /// the new address has taken this device.
    private func forgetMove() {
        guard let home = AppSettings.previousServiceAddress else { return }
        AppSettings.forgetPreviousAddress()
        // The move landed, so there is nothing left that this device tried and came home from:
        // whatever is held here is an address it has already left behind, and holding it could
        // only suppress the next move the deployment makes.
        AppSettings.abandonedServiceAddress = nil
        log("the address this app followed answered for this device — forgetting \(home), which "
            + "was the way back")
    }

    /// One pass at the service itself: the session, and then everything a loaded app needs from it.
    ///
    /// The distinction between the ways it fails is the whole of the recovery above. A service that
    /// does not answer, or that answers and will not take this device, has said something about the
    /// **address** — the one thing a followed move has to be judged by, and the one thing this
    /// device keeps a second answer for (`returnHome`). Anything that goes wrong after the session
    /// is this device's own data, and moving the address would be answering the wrong question.
    private func readService() async -> ReadOutcome {
        let session: (authenticated: Bool, configured: Bool, name: String?)
        do {
            session = try await client.checkSession()
        } catch {
            if Self.isCancellation(error) { return .answered(.cancelled) }
            log("load failed: \(error.localizedDescription)")
            return .unanswered(error.localizedDescription)
        }
        guard session.authenticated else {
            // An answer, and one about this device rather than about its data: the address heard
            // the request and would not take the caller.
            log("the service answered and would not take this device")
            return .refused("The service did not accept this device.")
        }
        // The address this device is dialling has now answered *for it*, which is the whole of what
        // "the move worked" can mean before the rest of a load has run, so the address it came from
        // is forgotten here. Deliberately before the check below: whether this service has anywhere
        // to put this device is a question about the device, and a server that accepted it has
        // settled the only question the way home was kept for.
        forgetMove()
        guard session.configured else {
            phase = .failed(refusal(authenticated: true))
            return .answered(.settled)
        }

        do {
            let bootstrap = try await client.bootstrap()
            me = bootstrap.user
            contacts = bootstrap.contacts

            // How the server says it is reached, against how this device was set up. Asked on
            // every load rather than once, because the administrator can switch it at any time
            // and the app has no other way to find out: the address changes with the mode, so a
            // device left pointing at the old one is a device nobody can reach to tell.
            //
            // The second ask of the same route in one load, and not a duplicate of the one
            // above: that one is what lets a device *follow* a move, and this one is the check
            // for a move it could not follow — a server too old to name its `origin`, whose
            // switch therefore still ends in being set up again. Asked after authenticating
            // because this is the comparison that is worth making only once the device has been
            // let in: a refusal the device got instead is about whether it belongs, not about
            // where it is.
            //
            // A refusal here is not a failure — a server that does not answer this is a server
            // this app can still use, and `serverMovedTo` stays as it was.
            if let health = try? await client.health() {
                let server = ConnectionMode.named(by: health.mode)
                // Only a device that *knows* what it was set up for can have been moved: one that
                // has never settled on a mode is not displaced by anything, it is the state the
                // onboarding screen exists for, and it has a screen of its own already.
                if let server, let mine = AppSettings.connectionMode, server != mine {
                    log("the server is reached as \(server.rawValue), and this device is set up "
                        + "for \(mine.rawValue)")
                    serverMovedTo = server
                } else {
                    serverMovedTo = nil
                }
            }

            phase = .ready
            // Before the event stream, so a device that enrolled a moment ago — the launch
            // PushKit announced a token on, which is when this happens — is ringable by the time
            // anything can try to ring it.
            await fileHeldPushTokens()
            startEvents()

            history = (try? await client.callHistory()) ?? []

            // What the stream could not tell this app: an invitation that arrived while it
            // was closed. Same path the reconnect uses, because a call that arrived while
            // the app was shut has to ring exactly like one that arrived while the stream
            // was down.
            await adopt(bootstrap)

            return .answered(.settled)
        } catch {
            if Self.isCancellation(error) { return .answered(.cancelled) }
            log("load failed: \(error.localizedDescription)")
            return .failed(error.localizedDescription)
        }
    }

    /// Attaches the carrier the current mode asks for, or says why the load cannot go on.
    ///
    /// Answers `nil` when the route is carrying. Split out of `attemptLoad` because one attempt
    /// may attach twice: a server that turns out to have moved changes the mode, and the mode is
    /// half of what chooses the route (see `followMovedServer`).
    private func attachRoute() async -> LoadOutcome? {
        do {
            hand(try await attachTransport())
            return nil
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
    }

    /// Follows a server that has moved, before this load authenticates anything.
    ///
    /// An administrator's switch reshapes the deployment, and the address moves with it — the two
    /// front doors are different names on different ports. The address this device already holds
    /// is the only thing that can be asked where the new one is, so the ask is made here, on the
    /// way into a load and before `/api/session`, and the answer is written straight into the two
    /// settings that *are* the deployment: the address and the mode. What the app then does is
    /// what it does on any load — dial that address — so the move costs the person nothing.
    ///
    /// **The device key is not touched, and that is the point.** What this device holds is an
    /// identity rather than a token tied to a host: the service remembers the public half of its
    /// key, and the same key authenticates at either door. `forgetServer()` is the only thing
    /// that deletes a key, and it is not reachable from here. Re-enrolling instead would mean the
    /// administrator issuing a code and hand-approving a device that had done nothing wrong.
    ///
    /// Only a device that already knows where it was set up can have been moved: with no address
    /// stored there is nothing for the answer to differ from, and a device in that state is being
    /// set up for the first time rather than displaced. Answers whether it adopted, which the
    /// caller turns into a second attach — the mode is half of what chooses the route.
    ///
    /// Following is deliberately **not a one-way door**, and the reason is measured rather than
    /// imagined: an address a deployment names is not always an address that answers, and a real
    /// switch on 2026-09-26 moved this app onto a front door that was not up. Nothing an address
    /// has just been given proves it will work — the only proof is a load that authenticates this
    /// device, which is the very thing that may fail — so the address this device came from is
    /// written down before the move is made, and `attemptLoad` goes back to it when the new one
    /// answers with nothing or refuses this device. Landing on a dead address with the working one
    /// gone is what costs an administrator a fresh invitation code and the person their
    /// enrollment, which is the whole cost a followed move exists to avoid.
    private func followMovedServer() async -> Bool {
        guard let stored = AppSettings.serviceAddress, let storedURL = URL(string: stored) else {
            return false
        }
        let health: ServiceHealth
        do {
            health = try await client.health()
        } catch {
            // Logged rather than dropped: a probe that never completes leaves no trace, which is
            // indistinguishable from one that answered "no move" — and this probe is the only
            // thing that can tell a person their Crossbar moved. The load carries on either way,
            // because an address that cannot answer this may still be the right address.
            log("could not ask the server where it is: \(error.localizedDescription)")
            return false
        }
        guard let reported = health.origin, !reported.isEmpty else {
            // A server older than this build, which is a peer and not a fault: D6 makes the
            // field additive for exactly this. Nothing about the address may be assumed from
            // its absence.
            return false
        }
        // `URL(string:)` answers for a relative string too, so the scheme and host are checked
        // rather than assumed: an `origin` this app cannot dial must leave the device where it
        // is, not move it to a name that resolves nowhere.
        guard let origin = URL(string: reported), origin.scheme != nil, origin.host != nil else {
            log("the server named an origin this app cannot dial (\(reported)) — staying where it is")
            return false
        }
        guard !ServiceAddress.isSameDeployment(origin, storedURL) else {
            // The deployment names the address this device is already on, so nothing is
            // outstanding — and a move this device once followed and came home from is spent the
            // moment the deployment stops making it. Holding it any longer could only make the app
            // withhold a move the deployment is making *now*.
            if AppSettings.abandonedServiceAddress != nil {
                AppSettings.abandonedServiceAddress = nil
                log("the server no longer says it moved — forgetting the address this device "
                    + "followed and came home from")
            }
            return false
        }

        // The move this device has already made and come home from. The deployment naming it
        // again is *not* something the device learns for the first time: it heard it on the load
        // that followed it, it heard it again on every load since, and each of those loads wrote
        // the address, dialled it, failed and announced the move to the person — the same notice
        // on a pull-to-refresh as on the load that made the move, which is what a loop looks like
        // from the outside. So the address is asked the one question that can have changed
        // (`/api/session`, about *this device*) before the move is made a second time, rather
        // than made in order to find out.
        //
        // Deliberately not a refusal to follow: a front door that comes up minutes after the app
        // looked — the measured shape of a real switch, 2026-09-26 — is still followed, on the
        // first load that finds it answering. That is the whole of what this remembers, and it is
        // why the address is kept rather than marked broken: the device stays where it works
        // until there is somewhere better to be, which is the reverse of the load that moves
        // first and recovers after.
        if let abandoned = AppSettings.abandonedServiceAddress,
           ServiceAddress.isSameDeployment(abandoned, reported) {
            guard await takesThisDevice(origin) else {
                log("the server still says it moved to \(reported), which this device already "
                    + "followed and came home from — staying where it is")
                return false
            }
            log("\(reported) takes this device now — following the move this device had come "
                + "home from")
            // And the person is told the move happened, because at this moment it does: the last
            // thing the load that failed told them was that the app had come back, and this is the
            // load that makes that no longer true. One notice per move that is actually made —
            // not one per load that hears about it, which is what the loop did.
        }

        // Where this device is now is written down before where it is going, and written only once
        // for a move that is still outstanding: what a device has to be able to get back to is
        // where it was before it started following, not the last address it tried, so a second
        // adoption on the way to a third address does not overwrite the way home. The mode comes
        // with it, because a move reshapes the way in as well as the name.
        if AppSettings.previousServiceAddress == nil {
            AppSettings.previousServiceAddress = stored
            AppSettings.previousConnectionMode = AppSettings.connectionMode
        }
        AppSettings.serviceAddress = origin.absoluteString
        // The move has been taken, so whatever this device had tried and come home from is spent:
        // what is left is where it is now, and the next load compares that against the same
        // answer. A stale address left here would suppress the *next* move the deployment makes.
        AppSettings.abandonedServiceAddress = nil
        // The mode the answer names, when this app knows that word. An answer that names an
        // address but no mode — or one from a build newer than this app's — still leaves the
        // address worth following: it is what the mode is needed to *dial*, and this device
        // already knows how it reaches its service.
        let adopted = ConnectionMode.named(by: health.mode)
        if let adopted, adopted != AppSettings.connectionMode {
            AppSettings.connectionMode = adopted
            log("the move changes how this device reaches its service — mode now \(adopted.rawValue)")
        }
        // What the service issued for this device, printed at the moment it is carried across:
        // the address moving is only harmless because this does not, so the log has to show the
        // one thing that would mean the app had re-enrolled instead of followed.
        //
        // The address on the right is what the device *holds*, not what the server spelled: it is
        // the value the next load compares this answer against, so a reader checking whether an
        // adoption survives that load is looking at the right string. What the server named is on
        // the line above, in `health()`'s own `origin=`.
        log("the server moved: \(stored) → \(AppSettings.serviceAddress ?? origin.absoluteString) "
            + "— following it; server mode=\(health.mode ?? "none"), "
            + "deviceId=\(DeviceAuth.shared.deviceId ?? "none") unchanged")
        notice = "Your Crossbar has moved, and this app followed it. Nothing here needs doing."
        return true
    }

    /// Whether the address a deployment names will take this device, asked of that address.
    ///
    /// The one question `followMovedServer` cannot answer from the answer it already has. The
    /// address the device is on says where the deployment *believes* it is; only the address
    /// itself can say whether this device belongs there, and `/api/session` is the route that
    /// answers exactly that — the same ask, of the same route, that a load makes the moment it
    /// arrives. Nothing weaker would do: a front door answering `/api/health` is a server that
    /// exists, not one that knows this device, and moving onto it to find out is what re-made the
    /// same move on every load.
    ///
    /// A failure to answer is a no. The address may still be the right one and merely not up yet,
    /// which is what keeps this from being a rejection: nothing is written, and the next load asks
    /// again.
    private func takesThisDevice(_ origin: URL) async -> Bool {
        do {
            return try await client.checkSession(at: origin).authenticated
        } catch {
            log("could not ask \(origin.absoluteString) whether it takes this device: "
                + error.localizedDescription)
            return false
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
                ? "This server did not accept this device. If it asks devices to enroll, "
                    + "paste the enrollment code you were given in Settings."
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
    func placeCall(to contact: Contact, video: Bool) {
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

    /// Ends a call whose signalling socket the client could not bring back.
    ///
    /// The socket **is** the room: with it gone there are no peers, no media, and no way for
    /// anything said about this call to be heard again. The client re-dials on a backoff and says
    /// so once that window has passed (`MiroTalkSignalClient.socketRecovery`), because retrying
    /// for the life of the app would only be a longer way of showing a call that is not
    /// happening. Three things are told, and each is a lie if it is not: the person, CallKit —
    /// which otherwise keeps a live call on the system UI — and the service, which otherwise
    /// keeps the call `active` and billed with no device in it.
    private func giveUpOnCall() async {
        // Only a call this device is actually carrying. The socket only exists for a call this
        // device dialled, so this is close to a formality — and it is the same formality the
        // CallKit end guard keeps, for the same reason: a call this device is not in is not this
        // device's to end.
        guard let call = phase.call, call.id == deviceCallID else { return }

        log("the signalling socket did not come back — ending call \(call.id)")
        // Ended locally first, because that part is instant and the person is owed it now: the
        // request below may not get through at all, since the network is exactly what failed.
        if let callID = callKitCallID { callKit.end(callID: callID) }
        await tearDown()
        notice = "The connection to this call was lost and could not be re-established, so the "
            + "call ended."

        do {
            try await client.end(callId: call.id)
            log("the service was told the call ended")
        } catch {
            // Said rather than swallowed: the service closes this device's dead socket out on its
            // own, but only `/end` finishes the call for everybody, and a failure here is why it
            // is still reading `active`.
            log("the service could not be told the call had ended: \(error.localizedDescription)")
        }
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
    private func resume(_ call: Call) async {
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
            ?? ServiceAddress.signallingOrigin(for: target.origin)
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

    /// Sets this device up again from nothing: the enrollment, the address and the mode.
    ///
    /// What the "your Crossbar has moved" screen offers, and the only thing that clears what a
    /// moved server leaves behind. Every one of those three belongs to the deployment they were
    /// issued by — the key and the id were issued *for* it, the address was its, and the mode is
    /// the one it has left — so a device pointing at a server it is no longer set up for has
    /// nothing worth keeping.
    func forgetServer() async {
        await tearDown()
        // Before anything local is forgotten, and that ordering is the whole of why this is here
        // rather than beside the relay code on the server: releasing this device at the deployment
        // is authenticated by this device's session, so a session already deleted cannot be
        // presented and the release can never be asked for afterwards. What it prevents is not
        // cosmetic — the deployment holds this phone's PushKit token at the relay, a relay token
        // has one owner, and a phone that enrols again while the old registration stands gets
        // `409 token_conflict` and is never rung (SEC-RELAY-04, REL-RELAY-03).
        await releaseThisDeviceAtTheService()
        DeviceAuth.shared.forget()
        AppSettings.serviceAddress = nil
        AppSettings.connectionMode = nil
        // The way home goes too. It is an address of the same deployment this device is being set
        // up again from nothing, and a way home left behind would put it back the first time
        // anything refused the device — which is undoing, by a side effect, the thing this screen
        // was asked to do.
        AppSettings.forgetPreviousAddress()
        // And the address a move it followed ended at: it too belongs to the deployment this
        // device is leaving, and a move from a deployment it is no longer set up for is not one it
        // should withhold.
        AppSettings.abandonedServiceAddress = nil
        serverMovedTo = nil
        // And the sentence about a phone that cannot be rung. It describes a token the *old*
        // deployment's relay refused, and this device is being set up from nothing against a new
        // one: the release above asked that deployment to let this device go, and a re-enrollment
        // files a fresh token on its first load — which is what earns the sentence back if the
        // conflict is still there. Keeping it would be this app refusing a deployment it is no
        // longer set up for, on the strength of an answer about a device row that no longer exists.
        pushTokenRefusals = PushTokenRefusals()
        needsSetup = true
        log("forgotten — this device has to be set up again")
    }

    /// Tells the deployment to let this device go, while this device can still prove who it is.
    ///
    /// Best-effort, and deliberately so: the person asked to be unpaired, and the unpairing itself
    /// is this device's to do whether or not the service answers — a refusal here must not leave
    /// them set up against a deployment they just left. What a failed call costs is written down
    /// instead: the row and the relay registration stay behind, and the things that clear them are
    /// the deployment's own retry of the release and the operator's removal.
    private func releaseThisDeviceAtTheService() async {
        guard let deviceId = DeviceAuth.shared.deviceId else { return }
        do {
            let ack = try await client.removeDevice(deviceId: deviceId)
            log("the service was told this device is being unpaired: removed=\(ack.removed), "
                + "relay=\(ack.relay?.described ?? "none")")
        } catch {
            log("could not tell the service this device is being unpaired "
                + "(\(error.localizedDescription)) — this phone's token may still be claimed there")
        }
    }

    /// This device has been set up: the mode is chosen, and the enrollment has settled who it
    /// is. The counterpart to `forgetServer`, and the only thing that clears `needsSetup`.
    ///
    /// While that flag is set the root view shows onboarding *instead of* the app, and nothing
    /// cleared it — so a device that was set up again finished onboarding onto a screen that put
    /// it straight back there, permanently. Measured on 2026-09-24: "You're in" arrived, the
    /// enrollment was done, and `/api/bootstrap` never ran, because the view that asks for it
    /// was never shown.
    func setupCompleted() {
        guard needsSetup else { return }
        needsSetup = false
        log("this device is set up — onboarding is done")
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
    private func adopt(_ bootstrap: Bootstrap) async {
        guard phase.call == nil else { return }
        contacts = bootstrap.contacts
        // The call a push named is taken first when it is in the list. The list holds every call
        // this person has not answered — an invitation left over from earlier still reads
        // `invited` — and ringing the wrong one puts a call on the system UI that cannot be
        // answered, because CallKit was told the id of the other. Without a push there is nothing
        // to prefer and the first invitation stands, as it always has. See `pushedCallID` and
        // `arrival`, which is what a push means once the service has been heard from.
        let reported = pushedCallID
        let mine = me?.id ?? ""
        let arrival = Self.arrival(pushed: reported, myUserId: mine, deviceCallID: deviceCallID,
                                   calls: bootstrap.calls, ongoing: bootstrap.ongoingCalls)
        // Consumed here, whatever it turned out to be. It exists to pick *this* ring out of the
        // list, and one that was left behind would have the next load deciding about a call that
        // is already over — and, for a call the service never had, asking CallKit to end one the
        // system has already forgotten, which comes back as an error about a call that does not
        // exist. `tearDown()` clears it too, for the paths that end a call without a load.
        pushedCallID = nil

        switch arrival {
        case .invited(let call):
            log("the call the push named is open on this device — ringing it")
            ring(call)

        case .ongoing(let call):
            await resume(call)

        case .unknown:
            // Only ever answered for a push, so there is an id to end by.
            if let reported { endUnbackedPush(reported) }

        case .unpushed:
            if let invited = bootstrap.calls.first(where: { $0.myStatus == "invited" }) {
                log("an invitation was waiting for this device — ringing it")
                ring(invited)
            } else if let ongoing = bootstrap.ongoingCalls.first(where: {
                Self.mayRejoin($0, deviceCallID: deviceCallID, myUserId: mine)
            }) {
                await resume(ongoing)
            }
        }
    }

    /// Which call the service says a reported push is, if it says anything at all.
    ///
    /// Pure and static, because it reads nothing of this session: it is given the things that
    /// decide — the id the push named, who this person is, which call this device joined, and what
    /// the load answered — and it is the whole of the question that used to be answered by falling
    /// back to the first open invitation. That fallback is right only when **no** push named a
    /// call: with a push in hand, ringing a different call asks the person to answer something
    /// CallKit was not told about while the call the push actually announced keeps ringing behind
    /// it (SEC-RELAY-05). An id the service does not name at all is `.unknown`, and the caller
    /// ends it.
    ///
    /// Matched by identity rather than by string, like every other comparison of a call id in this
    /// app: the two spellings of one UUID are the same call, and the service is free to choose
    /// either.
    static func arrival(
        pushed: UUID?,
        myUserId: String,
        deviceCallID: String?,
        calls: [Call],
        ongoing: [Call]
    ) -> PushedArrival {
        guard let pushed else { return .unpushed }
        if let invited = calls.first(where: { $0.myStatus == "invited" && UUID(uuidString: $0.id) == pushed }) {
            return .invited(invited)
        }
        if let active = ongoing.first(where: {
            UUID(uuidString: $0.id) == pushed
                && Self.mayRejoin($0, deviceCallID: deviceCallID, myUserId: myUserId)
        }) {
            return .ongoing(active)
        }
        return .unknown
    }

    /// Whether an active call is one this device may rejoin.
    ///
    /// Three things, and the first is the one that is easy to leave out. The service's identity is
    /// a person, not a device, so `/api/bootstrap` answers "am I in a call?" identically for every
    /// instance authenticating as that person — a second phone, a simulator, an Xcode preview. A
    /// call answered on one phone therefore reads as active *and this person's* on all of them, and
    /// membership is not evidence that **this** device was ever in it: measured 2026-09-18, an
    /// Xcode preview appeared as a third participant in a live call, with a black camera and a peer
    /// whose video never loaded. So the call has to be the one this device itself joined
    /// (`deviceCallID`, written by `accept` and `resume` and cleared by `tearDown`), the service
    /// has to still call it active, and this person has to be in it.
    static func mayRejoin(_ call: Call, deviceCallID: String?, myUserId: String) -> Bool {
        guard let deviceCallID, call.id == deviceCallID else { return false }
        return call.isActive && isMine(call, userId: myUserId)
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
    private func ring(_ call: Call) {
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

    /// Ends a call a push reported that the service does not have.
    ///
    /// The report cannot wait for the network — iOS ends an app that takes a VoIP push and reports
    /// nothing — so a push can put a call on the lock screen before anything has asked whether the
    /// service has one. A replayed push, a call cancelled between the relay sending the wake and
    /// this phone waking, a push for a call this service never minted, and a call this person
    /// answered on *another* phone all arrive here as the same thing: there is no invitation to
    /// respond to and no room this device may join. The load that follows the report is what asks,
    /// and this is where the answer is acted on. Leaving it ringing is the worst of the options
    /// available, because the person is being asked to answer a call that has nothing behind it —
    /// and for the call answered elsewhere, one they already answered.
    ///
    /// Ended **without a word to the person**, which is the other half of doing it properly: none
    /// of this is theirs to fix, nothing they could do would change it, and a notice explaining a
    /// push they never saw — most likely a cold launch from the lock screen — is noise draped over
    /// an app they have only just opened. The log line is where it is recorded, and
    /// `pushedCallID` has already been cleared by the caller, so no later load can ask CallKit to
    /// end this call a second time and collect an error about a call the system no longer has.
    private func endUnbackedPush(_ callID: UUID) {
        log("the call the push named (\(callID.uuidString.prefix(8))) is not one this service has "
            + "— ending it rather than leaving it ringing")
        callKit.end(callID: callID)
    }

    private func handle(_ event: ServiceEvent) {
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

    private func isMine(_ call: Call) -> Bool {
        Self.isMine(call, userId: me?.id ?? "")
    }

    /// The same question asked of an id rather than of this session's own, so the decision
    /// `arrival` makes reads no state of this instance. An empty id matches nobody, which is what
    /// a device that has not loaded its own identity should get: it is nobody's call.
    static func isMine(_ call: Call, userId: String) -> Bool {
        call.callerId == userId || (call.participants?.contains { $0.userId == userId } ?? false)
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

/// The push tokens this app is still trying to file.
///
/// A type of its own rather than a dictionary inside `CallSession`, because the two mistakes it
/// must not make are the two halves of REL-RELAY-01 and both are silent from the outside:
/// forgetting a token the relay has not got, which is a phone that never rings, and going on
/// offering one the relay will never take, which is a retry storm against an answer that cannot
/// change. `resolve` is where the deployment's verdict becomes one of those. The session supplies
/// the verdict and does the trying; this decides what is still waiting.
struct PendingPushTokens {
    private var held: [String: String] = [:]

    var isEmpty: Bool { held.isEmpty }

    /// What is waiting, one entry per token kind (`voip`, `alert`), as copies — so a loop over
    /// them can resolve into the set it is walking.
    var kinds: [String] { Array(held.keys) }
    var entries: [(kind: String, token: String)] { held.map { (kind: $0.key, token: $0.value) } }

    subscript(kind: String) -> String? { held[kind] }

    /// Keeps a token for the next attempt.
    mutating func hold(_ token: String, kind: String) {
        held[kind] = token
    }

    /// Applies the service's verdict to the token held for `kind`.
    ///
    /// Returns whether the token is still waiting, which is true of exactly one verdict: a
    /// retryable refusal. A token the deployment has filed is no longer this app's to offer, and
    /// one the relay will never take must not be offered again — dropping it is the whole of what
    /// `permanent` means here, and a phone refused that way is published instead
    /// (`CallSession.pushTokenRefusals`, which is where the words for it live).
    @discardableResult
    mutating func resolve(_ verdict: PushTokenVerdict, kind: String) -> Bool {
        switch verdict {
        case .filed, .permanent:
            held[kind] = nil
            return false
        case .retry:
            return held[kind] != nil
        }
    }
}

/// The push tokens the relay has refused for good, and what that means for the person.
///
/// The durable half of the same verdict `PendingPushTokens` takes, and a type of its own for the
/// same reason: both mistakes are silent. Saying nothing while the phone cannot be rung leaves
/// somebody waiting for calls that cannot arrive, and saying it after the phone can be rung again
/// is a screen crying wolf about a service that has already let go — `apply` is where a verdict
/// becomes one of the two.
///
/// The words are **read off** what is refused rather than stored beside it, which is the whole
/// point of the type: nobody can clear the sentence without clearing the condition, and there is
/// therefore nothing for a load to take down. It is a value rather than a `String` on the session
/// because that is what makes it comparable, testable and clearable in the one place the verdict
/// arrives.
struct PushTokenRefusals {
    private var codes: [String: String] = [:]

    var isEmpty: Bool { codes.isEmpty }

    /// What the person is told, or nothing while this phone can be rung.
    ///
    /// The kinds are named and sorted, so two refusals cannot produce a sentence whose wording
    /// depends on dictionary order, and the relay's own word for the refusal is carried through:
    /// `token_conflict` is what an operator — the only one who can release the token — needs in
    /// order to find it. Nothing here is a credential: an error code is the relay's vocabulary,
    /// and a token itself never appears in this app's copy.
    var sentence: String? {
        guard !codes.isEmpty else { return nil }
        let described = codes.sorted { $0.key < $1.key }
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")
        return "This phone cannot be rung yet — the service that sends the wake refused its push "
            + "token \(described). Only the server can release it."
    }

    /// Applies the deployment's verdict to what the person is being told.
    ///
    /// A retry changes nothing, and that is the case a load walks through on its way past: it is
    /// not an answer about the token, it is a service that could not be reached, and it must not
    /// take the sentence away. Filing is the only thing that ends a refusal, because it is the
    /// only thing that makes the phone ringable again.
    mutating func apply(_ verdict: PushTokenVerdict, kind: String) {
        switch verdict {
        case .filed:
            codes[kind] = nil
        case .permanent(let code):
            codes[kind] = code
        case .retry:
            break
        }
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
