@preconcurrency import AVFAudio
@preconcurrency import CallKit
import Foundation
import UIKit

/// CallKit for the product flow.
///
/// The probe's version existed to measure whether CallKit and WebRTC could share an
/// audio session. This one exists to put a real call on the system UI — the lock
/// screen, the in-call banner, the route picker, the buttons on a headset or car
/// system. It reports what the app is doing and calls back; it keeps **no call state
/// of its own**, because two owners of "which call is this" is how they come to
/// disagree.
@MainActor
final class CallKitController: NSObject, CXProviderDelegate, CXCallObserverDelegate {
    /// The system accepted a request to place a call. `handle` carries the contact id.
    var onStart: ((UUID, String) -> Void)?
    var onAnswer: ((UUID) -> Void)?
    var onEnd: ((UUID) -> Void)?
    var onMute: ((UUID, Bool) -> Void)?
    var onReset: (() -> Void)?
    var onAudioActivated: ((AVAudioSession) -> Void)?
    var onAudioDeactivated: ((AVAudioSession) -> Void)?
    var onError: ((String) -> Void)?

    /// A line about what CallKit did. Separate from `onError`, because an action
    /// arriving is not a failure — and it is the only record of *who* ended a call.
    /// An end that arrives with no preceding "app asked to end" line came from the
    /// system, which is otherwise indistinguishable in a log.
    var onLog: ((String) -> Void)?

    private let callController = CXCallController()

    /// The system's own view of the calls this app owns. Kept because it is the only
    /// place that shows what iOS thinks is happening — including whether it has
    /// decided a call is on hold or over — as opposed to what the app is doing.
    private let callObserver = CXCallObserver()

    private lazy var provider: CXProvider = {
        // Named rather than anonymous: Apple's own sample names the provider, and an
        // unnamed one is what the system UI has to attribute a call to.
        let configuration = CXProviderConfiguration(localizedName: "Crossbar")
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        // The household calls are two to four people; the extra headroom costs
        // nothing and a rejected join is invisible to everyone but the person who
        // could not get in.
        configuration.maximumCallsPerCallGroup = 4
        configuration.supportedHandleTypes = [.generic]

        let provider = CXProvider(configuration: configuration)
        provider.setDelegate(self, queue: .main)
        return provider
    }()

    override init() {
        super.init()
        // Created eagerly so the app is registered with CallKit before any transaction
        // is requested: `CXCallController.request(_:)` is rejected with
        // `CXErrorCodeRequestTransactionErrorUnknownCallProvider` when there is no
        // provider yet, and `provider` would otherwise only be touched on the incoming
        // path — which is how an outgoing call failed on a cold start.
        _ = provider
        callObserver.setDelegate(self, queue: .main)
    }

    /// Places the call on the system UI as an outgoing call.
    func startOutgoing(handle: String, video: Bool = true) -> UUID {
        let callID = UUID()
        let action = CXStartCallAction(call: callID, handle: CXHandle(type: .generic, value: handle))
        action.isVideo = video
        request(CXTransaction(action: action))
        return callID
    }

    /// Rings on the system UI.
    ///
    /// This is what makes the phone behave like a phone — but only while the app is
    /// running. A suspended app receives nothing, which is why a real incoming call
    /// still needs APNs and a device-token model that does not exist yet.
    func reportIncoming(callID: UUID, callerName: String, video: Bool = true) {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerName)
        update.localizedCallerName = callerName
        update.hasVideo = video
        provider.reportNewIncomingCall(with: callID, update: update) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onError?("CallKit could not report the call: \(error.localizedDescription)")
            }
        }
    }

    func reportConnected(callID: UUID) {
        provider.reportOutgoingCall(with: callID, connectedAt: Date())
    }

    /// Calls the app has already asked CallKit to end.
    ///
    /// Ending one twice is not harmless. The second `CXEndCallAction` comes back refused
    /// with `callUUIDInvalid`, which reached the person as "CallKit rejected the request:
    /// the operation couldn't be completed" moments after a call that had worked perfectly.
    /// The app ends a call from more than one path — the person's own end, and the teardown
    /// that follows the server confirming it — and CallKit cannot be asked twice. Measured
    /// 2026-09-21, on the first call between two phones.
    private var ended: Set<UUID> = []

    func end(callID: UUID) {
        guard !ended.contains(callID) else {
            onLog?("end already asked for — not asking CallKit a second time")
            return
        }
        ended.insert(callID)
        onLog?("app asked to end the call")
        request(CXTransaction(action: CXEndCallAction(call: callID)))
    }

    func setMuted(_ muted: Bool, callID: UUID) {
        request(CXTransaction(action: CXSetMutedCallAction(call: callID, muted: muted)))
    }

    private func request(_ transaction: CXTransaction) {
        callController.request(transaction) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in
                self?.onError?("CallKit rejected the request: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        onLog?("provider reset — every call is gone")
        onReset?()
    }

    /// CallKit gives an app a few seconds to perform an action; not performing one in
    /// time is silent unless it is written down, and it can end a call.
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        onLog?("timed out performing \(type(of: action))")
        onError?("CallKit timed out waiting for the call to be handled.")
    }

    func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        onLog?("performing start")
        action.fulfill()
        provider.reportOutgoingCall(with: action.callUUID, startedConnectingAt: Date())
        onStart?(action.callUUID, action.handle.value)
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        onLog?("performing answer")
        onAnswer?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        // Where the app stood when the system asked for the call to end. Recorded
        // because the lock path delivered no `willResignActive`: either the system
        // still considered this app frontmost while the screen was off, or it ended
        // the call before it ever told us we were losing the foreground.
        onLog?("performing end — app state=\(UIApplication.shared.applicationState.rawValue)")
        onEnd?(action.callUUID)
        action.fulfill()
    }

    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        onLog?("performing mute=\(action.isMuted)")
        onMute?(action.callUUID, action.isMuted)
        action.fulfill()
    }

    /// CallKit hands over a session **it** activated; WebRTC adopts that session
    /// rather than activating its own. See `CallMediaSource.adoptAudioSession`, and
    /// note that adopting it is only half the job — the gate has to be re-armed too.
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        onLog?("activated the audio session")
        onAudioActivated?(audioSession)
    }

    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        onLog?("deactivated the audio session")
        onAudioDeactivated?(audioSession)
    }

    // MARK: - CXCallObserverDelegate

    /// What the system believes, which is not always what the app believes.
    func callObserver(_ callObserver: CXCallObserver, callChanged call: CXCall) {
        onLog?("system view \(call.uuid.uuidString.prefix(8)): "
            + "ended=\(call.hasEnded) outgoing=\(call.isOutgoing) onHold=\(call.isOnHold) connected=\(call.hasConnected)")
    }
}
