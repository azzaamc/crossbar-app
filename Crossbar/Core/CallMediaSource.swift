@preconcurrency import AVFoundation
import Combine
import CoreMedia
import Foundation
import WebRTC

/// One local camera and microphone, shared by every peer connection.
///
/// A single capture feeding N senders: each peer connection adds the same tracks,
/// which is what MiroTalk's own client does with one local stream added to every
/// connection. An earlier revision gave each client its own capturer and they fought
/// over the capture session — both peers reported "media prepared" while only audio
/// was verifiably flowing.
@MainActor
final class CallMediaSource: ObservableObject {
    let factory: RTCPeerConnectionFactory
    let audioTrack: RTCAudioTrack
    let videoTrack: RTCVideoTrack

    private var capturer: RTCCameraVideoCapturer?
    private var started = false
    private var useFrontCamera = true

    /// Whether the app wants the camera running, as distinct from `started`, which only
    /// says the SDK has confirmed one. The two differ for about a second at the start of a
    /// capture, and a stop that lands in that second must still stop the camera.
    private var wanted = false

    /// Where the outcomes go. A camera start or switch finishes after the call that asked
    /// for it has returned, so the result has to be reported rather than returned.
    var log: (String) -> Void = { _ in }

    /// The switch in flight, if any. One at a time: two concurrent switches are two
    /// reconfigurations of one session.
    private var switchTask: Task<Void, Never>?

    init() {
        factory = RTCPeerConnectionFactory(
            encoderFactory: RTCDefaultVideoEncoderFactory(),
            decoderFactory: RTCDefaultVideoDecoderFactory()
        )
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        let audioSource = factory.audioSource(with: constraints)
        audioTrack = factory.audioTrack(with: audioSource, trackId: "crossbar-audio")
        let videoSource = factory.videoSource()
        videoTrack = factory.videoTrack(with: videoSource, trackId: "crossbar-video")
        capturer = RTCCameraVideoCapturer(delegate: videoSource)
    }

    /// Idempotent by design: three peers must not start three captures, which is
    /// exactly what went wrong when each client owned its own.
    ///
    /// The start is asynchronous and its outcome is logged when the SDK reports it. The
    /// previous version returned "capture started on …" the moment it had *asked*, which
    /// is a claim about a camera nobody had confirmed was running.
    @discardableResult
    func startCapture() -> String {
        guard !wanted, switchTask == nil else { return "capture already running" }
        wanted = true
        let position: AVCaptureDevice.Position = useFrontCamera ? .front : .back
        Task { [weak self] in
            guard let self else { return }
            let outcome = await self.start(on: position)
            self.log("capture → \(outcome.message)")
            // A stop that arrived while the start was in flight has to win, or the camera
            // runs on with nothing holding it. That is what left the camera light on after
            // an outgoing call nobody answered: the call ended within the second the start
            // took to be confirmed, the stop found no confirmed capture to stop, and the
            // capture it had asked for arrived afterwards.
            if !self.wanted, self.started {
                await self.stopCaptureAwaiting()
                self.started = false
                self.log("capture stopped — the stop arrived before the start was confirmed")
            }
        }
        return "capture starting on the \(name(of: position)) camera…"
    }

    private func start(on position: AVCaptureDevice.Position) async -> (didStart: Bool, message: String) {
        guard let capturer else { return (false, "no capturer") }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            return (false, "no capture device — audio only")
        }
        guard let choice = Self.chooseFormat(for: device,
                                             preferredPixelFormat: capturer.preferredOutputPixelFormat())
        else {
            return (false, "no usable format on \(device.localizedName) — audio only")
        }

        let error: Error? = await withCheckedContinuation { continuation in
            capturer.startCapture(with: device, format: choice.format, fps: choice.fps) {
                continuation.resume(returning: $0)
            }
        }
        if let error {
            return (false, "start failed on \(device.localizedName): \(error.localizedDescription)")
        }
        started = true
        let dimensions = CMVideoFormatDescriptionGetDimensions(choice.format.formatDescription)
        return (true, "\(device.localizedName) \(dimensions.width)x\(dimensions.height)@\(choice.fps)")
    }

    /// Re-acquires on the other camera.
    ///
    /// **Serialised, and that is the fix rather than a detail.** `stopCapture` and
    /// `startCapture` are both asynchronous — the SDK says so in both headers — and this
    /// used to call them back to back. The start therefore reconfigured the same
    /// `AVCaptureVideoDataOutput` while the previous session was still being dismantled on
    /// WebRTC's own dispatch queue, and AVFoundation threw from
    /// `-[AVCaptureVideoDataOutput setVideoSettings:]`. Swift cannot catch an Objective-C
    /// exception, so the app took `SIGABRT`: two crash reports on 2026-09-19, both
    /// `EXC_CRASH` / `Abort trap: 6`, both faulting on
    /// `org.webrtc.RTCDispatcherCaptureSession` the moment the camera was flipped during a
    /// call. The start now waits for the stop's completion handler.
    ///
    /// The position is only flipped once the switch has actually succeeded, so a failed
    /// switch no longer leaves the flag describing a camera that is not running.
    @discardableResult
    func switchCamera() -> String {
        guard wanted else { return "no capture to switch" }
        guard switchTask == nil else { return "a camera switch is already running" }
        let position: AVCaptureDevice.Position = useFrontCamera ? .back : .front
        switchTask = Task { [weak self] in
            guard let self else { return }
            await self.stopCaptureAwaiting()
            let outcome = await self.start(on: position)
            if outcome.didStart { self.useFrontCamera.toggle() }
            self.switchTask = nil
            self.log("flip → \(outcome.message)")
            // The call can end while a flip is in flight, and the flip's start would
            // otherwise hand back a running camera to a session that is already torn down.
            if !self.wanted, self.started {
                await self.stopCaptureAwaiting()
                self.started = false
                self.log("capture stopped — the call ended during the flip")
            }
        }
        return "switching to the \(name(of: position)) camera…"
    }

    /// Stops capture, and is authoritative about wanting it stopped.
    ///
    /// `wanted` is cleared first and unconditionally, so a start still in flight sees it and
    /// stops what it started when it lands — see `startCapture`. The old version guarded on
    /// a flag that only meant "the SDK has confirmed a capture", which is precisely what a
    /// stop arriving early could not see.
    func stopCapture() {
        wanted = false
        guard started else { return }
        started = false
        Task { [weak self] in
            guard let self else { return }
            await self.stopCaptureAwaiting()
            self.log("capture stopped")
        }
    }

    /// Stops the session and waits for the SDK to finish tearing it down.
    ///
    /// The wait is what keeps the next start from reconfiguring an output that is still
    /// connected to a running session — see `switchCamera()`.
    private func stopCaptureAwaiting() async {
        guard let capturer else { return }
        await withCheckedContinuation { continuation in
            capturer.stopCapture { continuation.resume() }
        }
    }

    private func name(of position: AVCaptureDevice.Position) -> String {
        position == .front ? "front" : "back"
    }

    /// A format the session can be reconfigured into.
    ///
    /// Deliberately **not** `.last`, which is what this used to pass. The tail of a
    /// device's format list is where the high-frame-rate and semi-compressed formats live,
    /// and WebRTC sets the output's `videoSettings` from the format it is handed — so this
    /// choice decides whether that property can be set at all. The frame rate has to sit
    /// inside one of the format's own ranges for the same reason: asking for a rate a format
    /// does not list is its own way to fail.
    ///
    /// Preference order: 1280x720, then the largest format at or below 1920 wide, then
    /// whatever is left. 720p is what a video call needs; capturing 4K in order to
    /// encode and send something much smaller costs CPU and battery on a call that can run
    /// for an hour.
    private static func chooseFormat(for device: AVCaptureDevice,
                                     preferredPixelFormat: FourCharCode)
        -> (format: AVCaptureDevice.Format, fps: Int)? {
        let usable = RTCCameraVideoCapturer.supportedFormats(for: device).compactMap {
            format -> (format: AVCaptureDevice.Format, width: Int, fps: Int)? in
            guard CMFormatDescriptionGetMediaSubType(format.formatDescription) == preferredPixelFormat
            else { return nil }
            let ranges = format.videoSupportedFrameRateRanges
            guard let fps = [30, 24, 15].first(where: { target in
                ranges.contains { $0.minFrameRate <= Double(target) && Double(target) <= $0.maxFrameRate }
            }) else { return nil }
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return (format, Int(dimensions.width), fps)
        }
        guard !usable.isEmpty else { return nil }
        let chosen = usable.first { $0.width == 1280 }
            ?? usable.filter { $0.width <= 1920 }.max { $0.width < $1.width }
            ?? usable.max { $0.width < $1.width }
        return chosen.map { ($0.format, $0.fps) }
    }

    /// The session underneath, which is the only place multitasking camera access can be
    /// turned on.
    var captureSession: AVCaptureSession? { capturer?.captureSession }

    /// Lets the camera keep running while the app is in Picture-in-Picture.
    ///
    /// iOS 16 opted the camera into PiP behind a per-session flag (the entitlement is only
    /// needed by apps targeting earlier than that). Until it is set, going to PiP costs
    /// the camera — so a video call silently became audio-only the moment it was
    /// minimised, which is not what any other calling app does and not what the person on
    /// the other end expects.
    ///
    /// Returns a line for the log either way: "this device cannot" is a fact about the
    /// hardware, not a failure of the call.
    @discardableResult
    func enableMultitaskingCamera() -> String {
        guard let session = captureSession else { return "no capture session yet — camera not kept for PiP" }
        guard session.isMultitaskingCameraAccessSupported else {
            return "this device cannot use the camera in PiP"
        }
        session.isMultitaskingCameraAccessEnabled = true
        return "camera kept for PiP (multitasking camera access on)"
    }

    /// Ungates WebRTC's audio, for a caller that has no CallKit call to do it.
    ///
    /// `prepareAudioSession()` puts the framework into manual-audio mode, so on its own
    /// **nothing is recorded or played** until this runs — the ADM sits idle. A process
    /// that is neither recording nor playing audio has no claim on background execution,
    /// which is what a call actually loses when the user leaves the app.
    ///
    /// Measured on 2026-09-19: with the probe's call up and audio still gated, leaving
    /// the app froze the process within seconds — the stats timer stopped writing, the
    /// far end saw the video stop, and MiroTalk removed the peer — and declaring `audio`
    /// in `UIBackgroundModes` changed none of it, because there was no audio running to
    /// justify the mode. CallKit sets this in `didActivate` (see `adoptAudioSession`);
    /// this is the same gate, opened by a caller that has no CallKit call to wait for.
    @discardableResult
    func enableAudio() -> String {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = true
        return "isAudioEnabled = true (media wants audio)"
    }

    // MARK: - Audio session

    /// Puts WebRTC in manual-audio mode, so **CallKit owns the audio session and
    /// WebRTC adopts it** rather than activating one of its own.
    ///
    /// Deliberately does not write `isAudioEnabled`. Setup can run after CallKit has
    /// already granted audio, and clearing the flag here silently undoes that grant —
    /// which is exactly what happened once: the first CallKit-first run showed
    /// `isAudioEnabled` falling back to 0 the moment capture started, and only the
    /// loopback raised it again.
    func prepareAudioSession() {
        RTCAudioSession.sharedInstance().useManualAudio = true
        _ = applyCallAudioConfiguration()
    }

    /// Puts the session into the configuration a call actually needs.
    ///
    /// Not optional, and not a default. Without it the session stayed
    /// `AVAudioSessionCategorySoloAmbient` in `AVAudioSessionModeDefault` — the state an
    /// app is left in when it never configures anything. SoloAmbient is playback-only,
    /// and `Default` mode engages no voice processing, so there was **no echo
    /// cancellation at all**; the audible result was echo loud enough that the
    /// microphone had to be muted to hold the conversation.
    ///
    /// Every metric we collect was healthy throughout. Echo is not visible in RTP byte
    /// counts, audio energy, or CallKit's own state — the only way to catch it is to
    /// look at what the session is configured as, which is why the values are logged.
    @discardableResult
    func applyCallAudioConfiguration() -> String {
        let rtc = RTCAudioSession.sharedInstance()
        let configuration = RTCAudioSessionConfiguration.webRTC()
        // WebRTC's own preference: playAndRecord, voiceChat, speaker by default and
        // Bluetooth allowed. Setting it as the WebRTC default as well as applying it
        // means the audio device module configures the same way when it starts.
        RTCAudioSessionConfiguration.setWebRTC(configuration)

        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try rtc.setConfiguration(configuration)
            return "audio session → \(configuration.category) / \(configuration.mode)"
        } catch {
            return "could not configure the audio session: \(error.localizedDescription)"
        }
    }

    /// Hands WebRTC the session CallKit just activated, and says what it applied.
    @discardableResult
    func adoptAudioSession(_ session: AVAudioSession) -> String {
        // Asserted before handing over, because the whole problem is that nobody else
        // did: the session arrived as SoloAmbient.
        let applied = applyCallAudioConfiguration()
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rearmAudio()
        return applied
    }

    func releaseAudioSession(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
    }

    /// Routes call audio to the speaker, or back to the receiver.
    ///
    /// Needed explicitly, because once CallKit activates the session **it** owns the
    /// route and defaults a call to the receiver — the `defaultToSpeaker` category
    /// option is not honoured after that. A video call coming out of the earpiece is not
    /// what anyone expects, and the system's own route control lives on CallKit's call
    /// screen rather than in this app.
    ///
    /// Only valid while the session is active, so this is applied on adoption as well as
    /// on demand.
    @discardableResult
    func setSpeaker(_ on: Bool) -> String {
        let rtc = RTCAudioSession.sharedInstance()
        // Every RTCAudioSession method that changes the underlying session requires this
        // lock, and skipping it fails silently as far as anything the user can hear:
        // the call simply keeps playing out of the receiver. The lock was applied for
        // `setConfiguration` and missed here.
        rtc.lockForConfiguration()
        defer { rtc.unlockForConfiguration() }
        do {
            try rtc.overrideOutputAudioPort(on ? .speaker : .none)
            return on ? "audio → speaker" : "audio → receiver"
        } catch {
            return "could not change the audio route: \(error.localizedDescription)"
        }
    }

    /// Forces the audio gate through a *real* transition.
    ///
    /// Assigning `true` when it is already `true` is not a change, so RTCAudioSession
    /// posts no `canPlayOrRecord`, the audio device module never re-evaluates, and no
    /// `setActive` ever reaches the session. That is precisely how a call once ran with
    /// completely dead audio while every metric read healthy — `rtcActive=1
    /// audioEnabled=1 audioUnit=1` — and it was found only by counting inbound RTP.
    /// Dropping to false and back raises exactly the notification that re-arms the path.
    func rearmAudio() {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.isAudioEnabled = true
    }
}
