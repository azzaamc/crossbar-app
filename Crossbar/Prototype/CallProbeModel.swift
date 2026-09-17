#if DEBUG
import Combine
import Foundation

@MainActor
final class CallProbeModel: ObservableObject {
    let mediaEngine = WebMediaEngine()

    @Published private(set) var status = "Loading runtime…"
    @Published private(set) var hasCall = false
    @Published private(set) var isMuted = false
    @Published private(set) var isCameraEnabled = true

    private let callKit = CallKitManager()
    /// Architecture B audio-seam spike. Independent of the web engine.
    let seamProbe = AudioSeamProbe()
    private var currentCallID: UUID?
    private var isMediaOnly = false
    private var processedLaunchArguments = false
    // Media-first outgoing experiment: acquire and start producing local media
    // before asking CallKit to take the audio session.
    private var awaitsCallKitAfterMedia = false
    private var mediaIsLive = false
    private var isSeamSpike = false

    init() {
        mediaEngine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        callKit.onStart = { [weak self] callID, video in
            guard let self else { return }
            if self.isSeamSpike {
                // Architecture B spike: a real CallKit call with the web engine
                // deliberately left out of the path.
                self.currentCallID = callID
                self.status = "Seam spike: CallKit call accepted"
                self.callKit.reportConnected(callID: callID)
                return
            }
            if self.mediaIsLive {
                // Media-first path: local capture is already running and producing
                // data, so adopt the CallKit call rather than re-acquiring media
                // after the session has changed hands.
                self.currentCallID = callID
                self.status = "CallKit accepted; local media was already active"
                self.callKit.reportConnected(callID: callID)
                return
            }
            self.beginMedia(callID: callID, video: video, reason: "outgoing")
        }
        callKit.onAnswer = { [weak self] callID in
            self?.beginMedia(callID: callID, video: true, reason: "answered")
        }
        callKit.onEnd = { [weak self] callID in
            self?.finish(callID: callID)
        }
        callKit.onMute = { [weak self] callID, muted in
            guard self?.currentCallID == callID else { return }
            self?.isMuted = muted
            self?.mediaEngine.setMuted(muted)
        }
        callKit.onReset = { [weak self] in
            self?.mediaEngine.leave()
            self?.clearCall(status: "CallKit reset")
        }
        callKit.onAudioActivationChanged = { [weak self] active in
            self?.mediaEngine.setAudioSessionActive(active)
        }
        callKit.onAudioActivated = { [weak self] session in
            self?.seamProbe.callKitDidActivate(session)
        }
        callKit.onAudioDeactivated = { [weak self] session in
            self?.seamProbe.callKitDidDeactivate(session)
        }
        callKit.onError = { [weak self] message in
            self?.mediaEngine.leave()
            self?.clearCall(status: message)
        }
    }

    func startOutgoingCall() {
        guard currentCallID == nil else { return }
        // Media-first experiment. In the original order CallKit activated the audio
        // session before WebKit held any capture, and WebKit then failed to activate
        // its own session and tore capture down. Acquiring and starting local media
        // before the transaction tests whether the ordering, rather than the
        // ownership boundary, is what breaks it.
        awaitsCallKitAfterMedia = true
        beginMedia(callID: UUID(), video: true, reason: "pre-call")
        status = "Acquiring local media before the CallKit call…"
    }

    /// Architecture B spike: start a CallKit call without the web engine, so the
    /// only media running is native. Answers whether RTCAudioSession adopts the
    /// CallKit-activated session instead of competing with it.
    func startSeamSpikeCall() {
        guard currentCallID == nil else { return }
        isSeamSpike = true
        hasCall = true
        status = "Seam spike: requesting outgoing CallKit call…"
        currentCallID = callKit.startOutgoing(video: true)
    }

    func simulateIncomingCall() {
        guard currentCallID == nil else { return }
        let callID = UUID()
        currentCallID = callID
        hasCall = true
        status = "Reporting simulated incoming call…"
        callKit.reportIncoming(callID: callID, video: true)
    }

    func startMediaOnly() {
        guard currentCallID == nil else { return }
        isMediaOnly = true
        beginMedia(callID: UUID(), video: true, reason: "media-only")
    }

    func toggleMute() {
        guard let currentCallID else { return }
        if isMediaOnly {
            isMuted.toggle()
            mediaEngine.setMuted(isMuted)
            return
        }
        callKit.setMuted(!isMuted, callID: currentCallID)
    }

    func toggleCamera() {
        isCameraEnabled.toggle()
        mediaEngine.setCameraEnabled(isCameraEnabled)
    }

    func switchCamera() {
        mediaEngine.switchCamera()
    }

    func endCall() {
        guard let currentCallID else { return }
        // No CallKit call exists yet on the media-only path, or on the media-first
        // path before media is live and the transaction has been requested, so end
        // locally instead of sending an unknown UUID to CallKit.
        if isMediaOnly || awaitsCallKitAfterMedia {
            finish(callID: currentCallID)
            return
        }
        callKit.end(callID: currentCallID)
    }

    func runLaunchArgumentsIfNeeded() {
        guard !processedLaunchArguments else { return }
        processedLaunchArguments = true
        if ProcessInfo.processInfo.arguments.contains("-CrossbarSimulateIncomingCall") {
            simulateIncomingCall()
        }
    }

    private func beginMedia(callID: UUID, video: Bool, reason: String) {
        currentCallID = callID
        hasCall = true
        status = "CallKit \(reason); requesting local media…"
        mediaEngine.join(callID: callID.uuidString, video: video)
    }

    private func finish(callID: UUID) {
        guard currentCallID == callID else { return }
        mediaEngine.leave()
        clearCall(status: "Call ended")
    }

    private func clearCall(status: String) {
        currentCallID = nil
        isMediaOnly = false
        awaitsCallKitAfterMedia = false
        mediaIsLive = false
        isSeamSpike = false
        hasCall = false
        isMuted = false
        isCameraEnabled = true
        self.status = status
    }

    private func handle(_ event: WebMediaEvent) {
        switch event.type {
        case "runtimeReady":
            status = "Runtime ready"
        case "joining":
            status = "Requesting camera and microphone…"
        case "joined":
            mediaIsLive = true
            if awaitsCallKitAfterMedia {
                awaitsCallKitAfterMedia = false
                status = "Local media active; requesting outgoing CallKit call…"
                currentCallID = callKit.startOutgoing(video: true)
                return
            }
            status = "Local media active"
            if let currentCallID, !isMediaOnly {
                callKit.reportConnected(callID: currentCallID)
            }
        case "mutedChanged":
            status = "Microphone state changed"
        case "cameraChanged":
            status = "Camera state changed"
        case "cameraSwitched":
            status = "Camera switched"
        case "playbackBlocked":
            status = "Local playback blocked: \(event.message ?? "unknown")"
        case "left":
            if currentCallID == nil {
                status = "Call ended"
            }
        case "error":
            status = event.message ?? "Web media runtime error"
        default:
            break
        }
    }
}
#endif
