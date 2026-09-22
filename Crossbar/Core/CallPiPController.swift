import AVKit
import CoreMedia
import Foundation
import WebRTC

/// The PiP window's content, rendered by an `AVSampleBufferDisplayLayer`.
///
/// This is what Apple tells video-call apps to use for the remote view, and the reason is
/// the one that showed up on hardware: Metal rendering is not driven while the app is in
/// the background, so a window built from the `RTCMTLVideoView` the call screen uses shows
/// a single frame — the last one drawn before the app left — and looks frozen until the
/// user comes back. A sample-buffer layer is fed by the system's own video path, so it
/// keeps presenting frames with the app behind.
final class SampleBufferCallView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // `layerClass` guarantees this, and a failed cast here means the class was changed
        // without changing this accessor.
        guard let layer = layer as? AVSampleBufferDisplayLayer else {
            fatalError("SampleBufferCallView's layer is not an AVSampleBufferDisplayLayer")
        }
        return layer
    }
}

/// Feeds decoded frames to that layer, and counts them.
///
/// The count is not decoration: a PiP window that shows a still picture and one that shows
/// live video look identical in a screenshot taken once, so the only honest evidence that
/// the window is live is frames continuing to arrive while the app is behind.
final class SampleBufferFrameRenderer: NSObject, RTCVideoRenderer {
    private let layer: AVSampleBufferDisplayLayer
    private let onProgress: (String) -> Void

    private var frames = 0
    private var framesAtLastReport = 0
    private var dropped = 0
    private var lastReport = Date()
    private var reportedNeverConvertible = false

    /// A pool per size, because the conversion runs at frame rate.
    private var pool: CVPixelBufferPool?
    private var poolWidth = 0
    private var poolHeight = 0

    /// The first few frames' geometry are reported: the shape of what arrives is not
    /// documented anywhere, and it decides whether the picture needs rotating.
    private var geometryReported = 0

    init(layer: AVSampleBufferDisplayLayer, onProgress: @escaping (String) -> Void) {
        self.layer = layer
        self.onProgress = onProgress
        super.init()
    }

    func setSize(_ size: CGSize) {
        // The layer sizes itself to the window; nothing to do.
    }

    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }

        guard let pixelBuffer = pixelBuffer(from: frame) else {
            // Said once rather than per frame: a silent drop here would look exactly like a
            // frozen window, which is the confusion this whole file exists to remove.
            if !reportedNeverConvertible {
                reportedNeverConvertible = true
                onProgress("PiP renderer: cannot use \(type(of: frame.buffer)) frames")
            }
            return
        }

        // A live call has no use for a backlog: if the layer is still presenting, queueing
        // more frames only adds latency, and the window ends up showing the past. Dropping
        // is reported rather than silent — "lagging" and "frozen" must not look the same.
        guard layer.isReadyForMoreMediaData else {
            dropped += 1
            return
        }
        enqueue(pixelBuffer, at: CMTime(value: Int64(frame.timeStampNs), timescale: 1_000_000_000))

        frames += 1
        let elapsed = Date().timeIntervalSince(lastReport)
        if elapsed > 5 {
            // Frames *since the last report*, not the running total: dividing a cumulative
            // count by one interval produced "140 fps" for a 30 fps stream, which is the
            // kind of number that gets quoted later without being checked.
            let sinceLastReport = frames - framesAtLastReport
            onProgress(String(
                format: "PiP renderer: %d frames total (%.1f fps over %.0f s, %d dropped)",
                frames, Double(sinceLastReport) / max(elapsed, 0.001), elapsed, dropped
            ))
            framesAtLastReport = frames
            lastReport = Date()
        }
    }

    /// The frame's pixels, in the form the layer takes.
    ///
    /// Two shapes arrive here: a decoded `CVPixelBuffer` when the decoder hands one over,
    /// and raw `RTCI420Buffer` when it does not — which is what this device actually
    /// produces (`PiP renderer: cannot use RTCI420Buffer frames`, 2026-09-19). The planar
    /// form is converted to NV12, interleaving U and V, because that is the layout a
    /// `CVPixelBuffer` can hold.
    private func pixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        if let converted = frame.buffer as? RTCCVPixelBuffer { return converted.pixelBuffer }
        guard let planar = frame.buffer as? RTCI420Buffer else { return nil }
        return nv12(from: planar, rotation: frame.rotation.rawValue)
    }

    private func nv12(from buffer: RTCI420Buffer, rotation: Int) -> CVPixelBuffer? {
        let width = Int(buffer.width)
        let height = Int(buffer.height)
        guard width > 0, height > 0 else { return nil }

        if geometryReported < 3 {
            geometryReported += 1
            onProgress("PiP renderer: frame \(width)x\(height) rotation=\(rotation) i420")
        }

        guard let output = poolBuffer(width: width, height: height) else { return nil }

        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }

        // Luma: row by row, because the source stride is the decoder's business.
        if let destination = CVPixelBufferGetBaseAddressOfPlane(output, 0) {
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0)
            let source = buffer.dataY
            let sourceStride = Int(buffer.strideY)
            for row in 0..<height {
                memcpy(
                    destination.advanced(by: row * destinationStride),
                    source.advanced(by: row * sourceStride),
                    min(width, min(sourceStride, destinationStride))
                )
            }
        }

        // Chroma: two separate planes into one interleaved plane.
        if let destination = CVPixelBufferGetBaseAddressOfPlane(output, 1) {
            let destinationStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1)
            let chromaWidth = (width + 1) / 2
            let chromaHeight = (height + 1) / 2
            let u = buffer.dataU
            let v = buffer.dataV
            let uStride = Int(buffer.strideU)
            let vStride = Int(buffer.strideV)
            for row in 0..<chromaHeight {
                let destinationRow = destination.advanced(by: row * destinationStride)
                    .assumingMemoryBound(to: UInt8.self)
                let uRow = u.advanced(by: row * uStride)
                let vRow = v.advanced(by: row * vStride)
                for column in 0..<chromaWidth {
                    destinationRow[column * 2] = uRow[column]
                    destinationRow[column * 2 + 1] = vRow[column]
                }
            }
        }

        return output
    }

    /// Reuses buffers instead of allocating one per frame — this runs at frame rate, and a
    /// fresh allocation per frame is exactly the kind of cost a call cannot afford.
    private func poolBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || poolWidth != width || poolHeight != height {
            let attributes: [CFString: Any] = [
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
            ]
            var created: CVPixelBufferPool?
            guard CVPixelBufferPoolCreate(
                kCFAllocatorDefault,
                nil,
                attributes as CFDictionary,
                &created
            ) == kCVReturnSuccess else { return nil }
            pool = created
            poolWidth = width
            poolHeight = height
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer) == kCVReturnSuccess else {
            return nil
        }
        return buffer
    }

    private func enqueue(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &format
        ) == noErr, let format else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: time,
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return }

        // A layer that has failed stays failed until it is flushed, and every frame after
        // that is dropped without complaint.
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sampleBuffer)
    }
}

/// Puts the remote video in a Picture-in-Picture window when the app is left mid-call.
///
/// A video call that survives backgrounding has one problem left: the screen the user
/// left shows the other person, so the picture disappears even though the call does not.
/// `AVPictureInPictureVideoCallViewController` is the surface Apple provides for calls
/// specifically, and it only works because the app keeps running when backgrounded — PiP
/// needs a live app and an active audio session, which is the same pair of ingredients
/// that keeps the call up at all.
///
/// **Arming is a foreground job.** The documentation is explicit that the system watches
/// the source view's layout frame and visibility and starts PiP *itself* when the app
/// moves to the background (`canStartPictureInPictureAutomaticallyFromInline`), which is
/// why this takes a track and a view while the app is in front rather than being asked for
/// from inside the background transition.
@MainActor
final class CallPiPController: NSObject {
    /// Where the outcome is reported. Nothing here fails silently: a window that never
    /// appeared is indistinguishable from one never asked for, and the delegate's error is
    /// the only place a reason exists.
    var onLog: ((String) -> Void)?

    private var controller: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var callView: SampleBufferCallView?
    private var renderer: SampleBufferFrameRenderer?
    /// The view the window grows out of, which the system watches to decide when to open it.
    /// Kept so a rebuilt call screen can replace it — see `arm`.
    private weak var sourceView: UIView?
    private weak var track: RTCVideoTrack?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isArmed: Bool { controller != nil }

    /// Prepares the window for a call: it appears when the app is backgrounded and shows
    /// `track`, growing out of `sourceView`.
    ///
    /// Idempotent for the same track and view, because callers arm it from wherever the two
    /// become available — the tile's view and the remote track arrive at different moments
    /// and neither is guaranteed to be second.
    ///
    /// A *different* pair means what it was built around is gone. The system starts PiP by
    /// watching the source view, and the call screen builds a new tile when it comes back to
    /// the foreground, so the arrangement has to be rebuilt around the new one rather than
    /// left pointing at a view that is no longer on screen. Checking only "is it armed" left
    /// exactly that stale controller behind.
    @discardableResult
    func arm(track: RTCVideoTrack, sourceView: UIView) -> Bool {
        guard isSupported else {
            onLog?("PiP is not supported on this device")
            return false
        }
        if isArmed, track === self.track, sourceView === self.sourceView { return true }
        if isArmed { teardown() }

        let callViewController = AVPictureInPictureVideoCallViewController()
        callViewController.preferredContentSize = CGSize(width: 360, height: 640)

        let callView = SampleBufferCallView(frame: callViewController.view.bounds)
        callView.translatesAutoresizingMaskIntoConstraints = false
        callView.displayLayer.videoGravity = .resizeAspectFill
        callViewController.view.addSubview(callView)
        NSLayoutConstraint.activate([
            callView.leadingAnchor.constraint(equalTo: callViewController.view.leadingAnchor),
            callView.trailingAnchor.constraint(equalTo: callViewController.view.trailingAnchor),
            callView.topAnchor.constraint(equalTo: callViewController.view.topAnchor),
            callView.bottomAnchor.constraint(equalTo: callViewController.view.bottomAnchor),
        ])

        let renderer = SampleBufferFrameRenderer(layer: callView.displayLayer) { [weak self] line in
            self?.onLog?(line)
        }
        track.add(renderer)

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: callViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // The system starts it when the app leaves; this flag says the call video is the
        // user's primary focus, which a call's video is.
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        self.callViewController = callViewController
        self.callView = callView
        self.renderer = renderer
        self.controller = controller
        self.track = track
        self.sourceView = sourceView

        onLog?("PiP armed (supported=\(isSupported), possible=\(controller.isPictureInPicturePossible))")
        return true
    }

    /// Closes the window while keeping the arrangement armed.
    ///
    /// Returning to the app has to take the window down — otherwise it floats over the
    /// call screen showing the same call twice — but it must not disarm, because the call
    /// still has video and the system should open the window again the next time the app is
    /// left. Measured on 2026-09-19: nothing dismisses it on the app's behalf, so an armed
    /// arrangement left alone keeps its window over the app indefinitely.
    func closeWindow() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
        onLog?("PiP window closed on return to the app")
    }

    /// Ends the arrangement — the call is over, or there is no video to show.
    ///
    /// The documentation is explicit that a video-call content source is for the duration
    /// of a call and must be cleared afterwards, so this drops the whole controller rather
    /// than only stopping the window.
    func disarm() {
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        teardown()
    }

    private func teardown() {
        if let renderer {
            track?.remove(renderer)
        }
        renderer = nil
        track = nil
        sourceView = nil
        callView?.removeFromSuperview()
        callView = nil
        controller?.contentSource = nil
        controller = nil
        callViewController = nil
    }
}

extension CallPiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in self.onLog?("PiP started") }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController
    ) {
        Task { @MainActor in
            // The window closing is not the arrangement ending.
            //
            // This tore the whole thing down, so the first return to the app disarmed PiP for
            // the rest of the call: the next trip to the background had nothing to start, and
            // the call carried on with audio only. `closeWindow` and `disarm` are the two ways
            // out, and only one of them means "this call has no video any more" — measured
            // 2026-09-22, on a call left and returned to twice.
            self.onLog?("PiP stopped — the arrangement stays armed")
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        Task { @MainActor in
            // Kept armed for the same reason. A start can fail for a reason that passes — the
            // app not yet eligible, the window not yet laid out — and tearing down here turned
            // one refusal into never again.
            self.onLog?("PiP failed to start: \(error.localizedDescription) — still armed")
        }
    }

    /// The window is going away because the user came back to the app; the call screen is
    /// already there, so there is nothing to rebuild by hand.
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
