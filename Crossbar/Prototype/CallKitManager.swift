#if DEBUG
@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation

@MainActor
final class CallKitManager: NSObject, CXProviderDelegate {
    var onStart: ((UUID, Bool) -> Void)?
    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onReset: (() -> Void)?
    var onAudioActivationChanged: ((Bool) -> Void)?
    var onAudioActivated: ((AVAudioSession) -> Void)?
    var onAudioDeactivated: ((AVAudioSession) -> Void)?
    var onError: ((String) -> Void)?

    private let callController = CXCallController()
    private lazy var provider: CXProvider = {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 4
        configuration.supportedHandleTypes = [.generic]

        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: .main)
        return provider
    }()

    override init() {
        super.init()
        // Create the provider eagerly so the app is registered with CallKit before
        // any transaction is requested. CXCallController.request(_:) is rejected
        // with CXErrorCodeRequestTransactionErrorUnknownCallProvider (code 2) if
        // the app has no provider, and `provider` is otherwise only touched by the
        // incoming-call path.
        _ = provider
    }

    func startOutgoing(video: Bool) -> UUID {
        let callID = UUID()
        let handle = CXHandle(type: .generic, value: "Architecture A probe")
        let action = CXStartCallAction(call: callID, handle: handle)
        action.isVideo = video
        request(CXTransaction(action: action))
        return callID
    }

    func reportIncoming(callID: UUID, video: Bool) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Family member")
        update.localizedCallerName = "Family member"
        update.hasVideo = video
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            guard let self, let error else { return }
            let message = "CallKit incoming report failed: \(error.localizedDescription)"
            Task { @MainActor [self, message] in
                self.onError?(message)
            }
        }
    }

    func end(callID: UUID) {
        request(CXTransaction(action: CXEndCallAction(call: callID)))
    }

    func setMuted(_ muted: Bool, callID: UUID) {
        request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted)))
    }

    func reportConnected(callID: UUID) {
        provider.reportOutgoingCall(with: callID, connectedAt: Date())
    }

    private func request(_ transaction: CXTransaction) {
        callController.request(transaction) { [weak self] error in
            guard let self, let error else { return }
            let message = "CallKit transaction failed: \(error.localizedDescription)"
            Task { @MainActor [self, message] in
                self.onError?(message)
            }
        }
    }

    func providerDidReset(_ provider: CXProvider) {
        onReset?()
    }

    // The probe deliberately does NOT configure AVAudioSession here. Doing so made
    // the app and WebKit two competing owners of the session: CallKit activated
    // the app's session and WebKit then failed to activate its own, treated that
    // as an interruption, and stopped the capture sources. Leaving WebKit as the
    // only owner on this path is what makes the ownership question measurable.
    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        onStart?(action.callUUID, action.isVideo)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        action.fulfill()
        onAnswer?(action.callUUID)
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        onEnd?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onMute?(action.callUUID, action.isMuted)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onAudioActivated?(audioSession)
        onAudioActivationChanged?(true)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onAudioDeactivated?(audioSession)
        onAudioActivationChanged?(false)
    }
}
#endif
