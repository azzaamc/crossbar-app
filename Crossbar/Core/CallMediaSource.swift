@preconcurrency import AVFoundation
import Combine
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
    @discardableResult
    func startCapture() -> String {
        guard !started else { return "capture already running" }
        return start(on: useFrontCamera ? .front : .back)
    }

    private func start(on position: AVCaptureDevice.Position) -> String {
        guard let capturer else { return "no capturer" }
        let devices = RTCCameraVideoCapturer.captureDevices()
        guard let device = devices.first(where: { $0.position == position }) ?? devices.first else {
            return "no capture device — audio only"
        }
        guard let format = RTCCameraVideoCapturer.supportedFormats(for: device).last else {
            return "no capture format — audio only"
        }
        capturer.startCapture(with: device, format: format, fps: 30)
        started = true
        return "capture started on \(device.localizedName)"
    }

    /// Re-acquires on the other camera.
    ///
    /// Stop-then-start rather than `RTCCameraVideoCapturer.switchCamera()`: the only
    /// path this project has measured is re-acquisition, and a swap that silently
    /// changes nothing is worse than one that visibly restarts.
    @discardableResult
    func switchCamera() -> String {
        guard started else { return "no capture to switch" }
        useFrontCamera.toggle()
        capturer?.stopCapture()
        started = false
        return start(on: useFrontCamera ? .front : .back)
    }

    func stopCapture() {
        guard started else { return }
        capturer?.stopCapture()
        started = false
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
    }

    /// Hands WebRTC the session CallKit just activated.
    func adoptAudioSession(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.audioSessionDidActivate(session)
        rearmAudio()
    }

    func releaseAudioSession(_ session: AVAudioSession) {
        let rtc = RTCAudioSession.sharedInstance()
        rtc.isAudioEnabled = false
        rtc.audioSessionDidDeactivate(session)
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
