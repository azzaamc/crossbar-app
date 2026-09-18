#if DEBUG
import AVFAudio
import Combine
import Foundation
import SwiftUI
import UIKit
import WebRTC

/// Architecture B audio-seam spike.
///
/// The Architecture A probe proved that WebKit cannot hold an audio session while
/// CallKit owns one: WebKit owns activation inside the WebContent process, loses
/// the arbitration, and tears its capture down (see `docs/ARCHITECTURE_A_PROBE.md`
/// P8.10/P8.13/P8.14).
///
/// Native WebRTC is built the other way round. `RTCAudioSession` exists to adopt an
/// activation that happened outside it — its activation delegate header says the
/// known use case "is when CallKit activates the audio session for the application"
/// — after which its own `setActive:` becomes a no-op. This probe measures on real
/// hardware whether that actually holds: that local capture survives the handover
/// and that WebRTC does not fight CallKit for the session.
///
/// This is a measurement instrument, not product code.
@MainActor
final class AudioSeamProbe: NSObject, ObservableObject {
    @Published private(set) var status = "Not started"
    @Published private(set) var lines: [String] = []
    @Published private(set) var isCapturing = false
    @Published private(set) var rtcSessionIsActive = false
    @Published private(set) var audioEnabled = false
    @Published private(set) var playOrRecordCount = 0

    private(set) var videoTrack: RTCVideoTrack?

    private var factory: RTCPeerConnectionFactory?
    private var pc1: RTCPeerConnection?
    private var pc2: RTCPeerConnection?
    private var videoSource: RTCVideoSource?
    private var audioSource: RTCAudioSource?
    private var audioTrack: RTCAudioTrack?
    private var capturer: RTCCameraVideoCapturer?
    /// Counts frames the capture source actually produced. The preview cannot be
    /// trusted for this: RTCMTLVideoView keeps its last frame after the track is
    /// detached, so a frozen picture and a live one look identical.
    private let frameCounter = SeamFrameCounter()
    private var didObserveLifecycle = false

    private var statsTimer: Timer?
    private var lastAudioBytes = -1
    private var logHandle: FileHandle?
    private var didActivateCount = 0
    private var didDeactivateCount = 0

    // MARK: - Lifecycle

    override init() {
        super.init()
        observeLifecycle()
    }

    /// App lifecycle is logged so cause can be separated from effect. Without it a
    /// lock or background test cannot distinguish "nothing happened" from "the app
    /// was suspended and we saw nothing".
    private func observeLifecycle() {
        guard !didObserveLifecycle else { return }
        didObserveLifecycle = true
        let events: [(Notification.Name, String)] = [
            (UIApplication.willResignActiveNotification, "app willResignActive"),
            (UIApplication.didEnterBackgroundNotification, "app didEnterBackground"),
            (UIApplication.willEnterForegroundNotification, "app willEnterForeground"),
            (UIApplication.didBecomeActiveNotification, "app didBecomeActive"),
        ]
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) ?? 0
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let label = raw == AVAudioSession.InterruptionType.began.rawValue
                ? "BEGAN"
                : (raw == AVAudioSession.InterruptionType.ended.rawValue ? "ENDED" : "unknown")
            Task { @MainActor in
                guard let self else { return }
                self.append("AVAudioSession interruption \(label) (raw \(raw)) options=\(options)")
                self.refresh()
            }
        }

        NotificationCenter.default.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.append("AVAudioSession media services were RESET")
                self?.refresh()
            }
        }

        for (name, label) in events {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.append("\(label)  frames=\(self.frameCounter.count)  audioUnit=\(self.playOrRecordCount)")
                    self.refresh()
                }
            }
        }
    }

    func start() {
        guard !isCapturing else { return }
        configureAudioSession()
        startCapture()
        isCapturing = true
        status = "Capture running — now start a CallKit call"
        append("capture started")
        refresh()
    }

    func stop() {
        statsTimer?.invalidate()
        statsTimer = nil
        lastAudioBytes = -1
        pc1?.close()
        pc2?.close()
        pc1 = nil
        pc2 = nil
        capturer?.stopCapture()
        capturer = nil
        RTCAudioSession.sharedInstance().remove(self)
        RTCAudioSession.sharedInstance().isAudioEnabled = false
        isCapturing = false
        videoTrack?.remove(frameCounter)
        videoTrack = nil
        status = "Stopped"
        append("capture stopped (frames produced: \(frameCounter.count))")
        refresh()
    }

    // MARK: - CallKit handover

    /// Called from `CXProviderDelegate.provider(_:didActivate:)`. This is the whole
    /// point of the spike: hand the session CallKit activated to WebRTC so it
    /// adopts it rather than activating it again.
    func callKitDidActivate(_ session: AVAudioSession) {
        didActivateCount += 1
        let rtc = RTCAudioSession.sharedInstance()
        append("didActivate #\(didActivateCount): rtc.isActive before = \(rtc.isActive)")
        rtc.audioSessionDidActivate(session)
        // Force a real gate transition. Assigning true when it is already true is not a
        // change, so RTCAudioSession never notifies canPlayOrRecord, the ADM never
        // re-evaluates its audio unit, and no setActive ever reaches the session. That
        // is how audio stayed dead for the whole of a call when capture was already
        // running: metrics read 1/1/1 and the audio unit kept claiming to run. Dropping
        // to false and back raises exactly the notification that re-arms the path.
        rtc.isAudioEnabled = false
        rtc.isAudioEnabled = true
        append("adopted by RTCAudioSession; forced canPlayOrRecord transition")
        status = "CallKit call active — watch whether the preview survives"
        refresh()
    }

    /// Called from `CXProviderDelegate.provider(_:didDeactivate:)`.
    func callKitDidDeactivate(_ session: AVAudioSession) {
        didDeactivateCount += 1
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
        append("didDeactivate #\(didDeactivateCount): isAudioEnabled = false, session returned")
        status = "CallKit call ended"
        refresh()
    }

    // MARK: - Setup

    private func configureAudioSession() {
        let config = RTCAudioSessionConfiguration.webRTC()
        config.category = AVAudioSession.Category.playAndRecord.rawValue
        config.mode = AVAudioSession.Mode.voiceChat.rawValue
        config.categoryOptions = [.allowBluetooth]
        RTCAudioSessionConfiguration.setWebRTC(config)

        let rtc = RTCAudioSession.sharedInstance()
        rtc.useManualAudio = true
        rtc.add(self)
        // Deliberately does NOT write isAudioEnabled. In the CallKit-first ordering
        // this setup runs AFTER didActivate has already granted audio, so clearing it
        // here silently undoes CallKit's grant - which is exactly what happened: the
        // first CallKit-first run showed isAudioEnabled falling back to 0 when capture
        // started, and only the loopback raised it again. Teardown in `stop()` is
        // still what disables it.
        append("configured playAndRecord/voiceChat; useManualAudio=1 isAudioEnabled=\(rtc.isAudioEnabled ? 1 : 0) left alone")
    }

    private func startCapture() {
        let factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        self.factory = factory

        let videoSource = factory.videoSource()
        self.videoSource = videoSource
        videoTrack = factory.videoTrack(with: videoSource, trackId: "seam-video")
        videoTrack?.add(frameCounter)

        let audioSource = factory.audioSource(
            with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        )
        self.audioSource = audioSource
        audioTrack = factory.audioTrack(with: audioSource, trackId: "seam-audio")

        let capturer = RTCCameraVideoCapturer(delegate: videoSource)
        self.capturer = capturer

        guard
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first
        else {
            append("no capture device available")
            return
        }
        let formats = RTCCameraVideoCapturer.supportedFormats(for: device)
        guard let format = formats.last else {
            append("no capture format for \(device.localizedName)")
            return
        }
        capturer.startCapture(with: device, format: format, fps: 30)
        append("capturer started on \(device.localizedName)")
    }

    // MARK: - Loopback

    /// The spike so far proves the session is adopted and capture survives, but the
    /// audio unit never started because nothing consumed the audio track - WebRTC's
    /// ADM only configures itself when audio is actually needed. This wires two
    /// peer connections together inside the app so playout and record are genuinely
    /// exercised, which is what turns "capture survives" into "audio runs".
    func startLoopback() {
        guard let factory else {
            append("start capture first")
            return
        }
        guard pc1 == nil else {
            append("loopback already running")
            return
        }

        let config = RTCConfiguration()
        config.sdpSemantics = .unifiedPlan
        config.iceServers = []
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)

        guard
            let pc1 = factory.peerConnection(with: config, constraints: constraints, delegate: self),
            let pc2 = factory.peerConnection(with: config, constraints: constraints, delegate: self)
        else {
            append("could not create peer connections")
            return
        }
        self.pc1 = pc1
        self.pc2 = pc2

        if let audioTrack {
            _ = pc1.add(audioTrack, streamIds: ["loopback"])
            _ = pc2.add(audioTrack, streamIds: ["loopback"])
        }
        if let videoTrack {
            _ = pc1.add(videoTrack, streamIds: ["loopback"])
        }

        pc1.offer(for: constraints) { [weak self] offer, error in
            Task { @MainActor in
                guard let self else { return }
                guard let offer else {
                    self.append("offer failed: \(error?.localizedDescription ?? "unknown")")
                    return
                }
                pc1.setLocalDescription(offer) { _ in
                    pc2.setRemoteDescription(offer) { _ in
                        pc2.answer(for: constraints) { answer, _ in
                            guard let answer else {
                                Task { @MainActor in self.append("answer failed") }
                                return
                            }
                            pc2.setLocalDescription(answer) { _ in
                                pc1.setRemoteDescription(answer) { _ in
                                    Task { @MainActor in self.append("loopback negotiated") }
                                }
                            }
                        }
                    }
                }
            }
        }
        // With useManualAudio on, audio stays gated until isAudioEnabled is set. The
        // CallKit path sets it in didActivate; enable it here too so the loopback on
        // its own can actually exercise the audio unit.
        RTCAudioSession.sharedInstance().isAudioEnabled = true
        append("isAudioEnabled = true (media wants audio)")
        status = "Loopback negotiating — audio unit should start"
        append("loopback started")
        startStatsPolling()
        refresh()
    }

    /// Counting audio-unit starts cannot show whether audio is actually flowing,
    /// which is precisely the question an interruption raises. These are the
    /// inbound-RTP byte and energy counters: a climbing byte count is audio moving,
    /// a flat one is silence regardless of what the audio unit claims.
    private func startStatsPolling() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollAudioStats() }
        }
    }

    private func pollAudioStats() {
        guard let pc2 else { return }
        pc2.statistics { [weak self] report in
            var found: (bytes: Int, energy: Double)?
            for (_, stat) in report.statistics {
                guard stat.type == "inbound-rtp",
                      let kind = stat.values["kind"] as? String,
                      kind == "audio"
                else { continue }
                found = (
                    (stat.values["bytesReceived"] as? NSNumber)?.intValue ?? 0,
                    (stat.values["totalAudioEnergy"] as? NSNumber)?.doubleValue ?? 0
                )
            }
            Task { @MainActor in
                guard let self else { return }
                guard let found else {
                    self.append("audio IN: no inbound audio stats yet")
                    self.refresh()
                    return
                }
                let delta = self.lastAudioBytes >= 0 ? found.bytes - self.lastAudioBytes : found.bytes
                self.lastAudioBytes = found.bytes
                let energy = String(format: "%.3f", found.energy)
                self.append("audio IN bytes=\(found.bytes) delta=\(delta) energy=\(energy)")
                self.refresh()
            }
        }
    }

    // MARK: - Reporting

    private func refresh() {
        let rtc = RTCAudioSession.sharedInstance()
        rtcSessionIsActive = rtc.isActive
        audioEnabled = rtc.isAudioEnabled
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > 40 { lines.removeFirst(lines.count - 40) }
        writeToLogFile(line)
    }

    /// The in-app view shows about a dozen lines and the buffer holds forty, which has
    /// already cost two measurements. The same lines go to Documents/seam.log, which is
    /// pulled off the device directly so the whole ordered sequence survives. The file
    /// is truncated on the first write of each launch.
    private func writeToLogFile(_ line: String) {
        if logHandle == nil {
            let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            let url = dir.appendingPathComponent("seam.log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: url)
            logHandle?.truncateFile(atOffset: 0)
        }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        logHandle?.write(data)
    }
}

extension AudioSeamProbe: RTCAudioSessionDelegate {
    // Every method on this protocol takes RTCAudioSession, NOT AVAudioSession. An
    // earlier revision used AVAudioSession, so none of these matched the ObjC
    // selectors and the instrumentation was silently dead - no canPlayOrRecord, no
    // audio-unit events, nothing.
    nonisolated func audioSession(
        _ session: RTCAudioSession,
        didChangeCanPlayOrRecord canPlayOrRecord: Bool
    ) {
        Task { @MainActor in
            self.append("canPlayOrRecord = \(canPlayOrRecord)")
            self.refresh()
        }
    }

    nonisolated func audioSessionDidStartPlayOrRecord(_ session: RTCAudioSession) {
        Task { @MainActor in
            self.playOrRecordCount += 1
            self.append("audio unit STARTED (play/record) #\(self.playOrRecordCount)")
            self.refresh()
        }
    }

    nonisolated func audioSessionDidStopPlayOrRecord(_ session: RTCAudioSession) {
        Task { @MainActor in
            self.append("audio unit STOPPED")
            self.refresh()
        }
    }

    // Interruption was previously unobservable here: none of these were implemented,
    // so an interruption could occur and leave no trace in the log. All are @optional
    // on the protocol, so the omission compiled silently.
    nonisolated func audioSessionDidBeginInterruption(_ session: RTCAudioSession) {
        Task { @MainActor in
            self.append("INTERRUPTION began (RTCAudioSession)")
            self.refresh()
        }
    }

    nonisolated func audioSessionDidEndInterruption(
        _ session: RTCAudioSession,
        shouldResumeSession: Bool
    ) {
        Task { @MainActor in
            self.append("INTERRUPTION ended, shouldResume=\(shouldResumeSession)")
            self.refresh()
        }
    }

    nonisolated func audioSessionMediaServerTerminated(_ session: RTCAudioSession) {
        Task { @MainActor in
            self.append("media server TERMINATED")
            self.refresh()
        }
    }

    nonisolated func audioSessionMediaServerReset(_ session: RTCAudioSession) {
        Task { @MainActor in
            self.append("media server RESET")
            self.refresh()
        }
    }

    /// Direct evidence for or against the adoption mechanism. WebRTC's setActive: is
    /// supposed to be a no-op while CallKit holds the session, so if these fire with
    /// true while a call is active, the suppression is not happening.
    nonisolated func audioSession(_ session: RTCAudioSession, willSetActive active: Bool) {
        Task { @MainActor in
            self.append("WebRTC willSetActive \(active)")
        }
    }

    nonisolated func audioSession(_ session: RTCAudioSession, didSetActive active: Bool) {
        Task { @MainActor in
            self.append("WebRTC didSetActive \(active)")
            self.refresh()
        }
    }

    nonisolated func audioSessionDidChangeRoute(
        _ session: RTCAudioSession,
        reason: AVAudioSession.RouteChangeReason,
        previousRoute: AVAudioSessionRouteDescription
    ) {
        let name = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
        let raw = reason.rawValue
        Task { @MainActor in
            self.append("route change \(raw) \(seamRouteReasonName(raw)) -> \(name)")
        }
    }
}

extension AudioSeamProbe: RTCPeerConnectionDelegate {
    // Required by the protocol; only the ones that carry signal are logged.
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        let raw = newState.rawValue
        Task { @MainActor in
            self.append("ice state -> \(raw)")
            self.refresh()
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        Task { @MainActor in
            if peerConnection === self.pc1 {
                self.pc2?.add(candidate) { _ in }
            } else {
                self.pc1?.add(candidate) { _ in }
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}

    // Optional; these are the ones worth reporting.
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        let raw = newState.rawValue
        Task { @MainActor in
            self.append("pc state -> \(raw)")
            self.refresh()
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd rtpReceiver: RTCRtpReceiver,
        streams: [RTCMediaStream]
    ) {
        Task { @MainActor in
            self.append("remote track received")
            self.refresh()
        }
    }
}

/// Counts produced frames. `RTCVideoRenderer` is called on WebRTC's thread, so the
/// counter is guarded rather than main-actor isolated.
final class SeamFrameCounter: NSObject, RTCVideoRenderer {
    private let lock = NSLock()
    private var value = 0

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func setSize(_ size: CGSize) {}

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard frame != nil else { return }
        lock.lock()
        value += 1
        lock.unlock()
    }
}

/// 6 is `wakeFromSleep`, which unlock should produce; its absence is meaningful.
private func seamRouteReasonName(_ raw: UInt) -> String {
    switch raw {
    case 1: return "newDeviceAvailable"
    case 2: return "oldDeviceUnavailable"
    case 3: return "categoryChange"
    case 4: return "override"
    case 6: return "wakeFromSleep"
    case 7: return "noSuitableRouteForCategory"
    case 8: return "routeConfigurationChange"
    default: return "unknown"
    }
}

struct AudioSeamView: View {
    @ObservedObject var probe: AudioSeamProbe
    let model: CallProbeModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Button(probe.isCapturing ? "Stop capture" : "Start capture") {
                    probe.isCapturing ? probe.stop() : probe.start()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("seam.capture")

                Button("Start CallKit call") {
                    model.startSeamSpikeCall()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("seam.call")

                Button("End CallKit call") {
                    model.endCall()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("seam.end")
            }

            HStack {
                Button("Start loopback") {
                    probe.startLoopback()
                }
                .buttonStyle(.bordered)
                .accessibilityIdentifier("seam.loopback")
            }

            RTCVideoSurface(track: probe.videoTrack)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(probe.status)
                .font(.footnote.weight(.semibold))
                .multilineTextAlignment(.center)

            Text("rtcActive=\(probe.rtcSessionIsActive ? "1" : "0")  audioEnabled=\(probe.audioEnabled ? "1" : "0")  audioUnit=\(probe.playOrRecordCount)")
                .font(.caption.monospaced())

            BackendReachabilitySection()

            SignalProbeSection()

            FamilyCallSection()

            ScrollView {
                Text(probe.lines.joined(separator: "\n"))
                    .font(.caption2.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 130)
            // Defaulting to the oldest lines hides the ones just produced - which is how
            // an interruption result was lost once already. Always show the tail.
            .defaultScrollAnchor(.bottom)
        }
    }
}
#endif
