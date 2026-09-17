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
    private var currentCallID: UUID?
    private var isMediaOnly = false
    private var processedLaunchArguments = false

    init() {
        mediaEngine.onEvent = { [weak self] event in
            self?.handle(event)
        }
        callKit.onStart = { [weak self] callID, video in
            self?.beginMedia(callID: callID, video: video, reason: "outgoing")
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
        callKit.onError = { [weak self] message in
            self?.mediaEngine.leave()
            self?.clearCall(status: message)
        }
    }

    func startOutgoingCall() {
        guard currentCallID == nil else { return }
        status = "Requesting outgoing CallKit call…"
        currentCallID = callKit.startOutgoing(video: true)
        hasCall = true
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
        if isMediaOnly {
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
