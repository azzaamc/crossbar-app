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
        guard let capturer else { return "no capturer" }
        guard
            let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == .front })
                ?? RTCCameraVideoCapturer.captureDevices().first
        else { return "no capture device — audio only" }
        guard let format = RTCCameraVideoCapturer.supportedFormats(for: device).last else {
            return "no capture format — audio only"
        }
        capturer.startCapture(with: device, format: format, fps: 30)
        started = true
        return "capture started on \(device.localizedName)"
    }

    func stopCapture() {
        guard started else { return }
        capturer?.stopCapture()
        started = false
    }
}
