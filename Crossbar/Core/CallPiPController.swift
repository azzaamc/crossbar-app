import AVKit
import Foundation
import WebRTC

/// Puts the remote video in a Picture-in-Picture window when the app is left mid-call.
///
/// A video call that survives backgrounding has one problem left: the screen the user
/// left shows the other person, so the picture disappears even though the call does not.
/// `AVPictureInPictureVideoCallViewController` is the surface Apple provides for calls
/// specifically, and the app only qualifies for it because it already keeps running when
/// backgrounded — PiP needs a live app and an active audio session, which is the same
/// pair of ingredients that keeps the call up at all.
///
/// **Arming is a foreground job.** The header is explicit that the system watches the
/// source view's layout frame and visibility and starts PiP *itself* when the app moves to
/// the background (`canStartPictureInPictureAutomaticallyFromInline`), which is why this
/// takes a track and a view while the app is in front rather than being called at the
/// moment the user leaves — asking for PiP from inside the background transition is the
/// unreliable version of the same request.
///
/// It renders through its **own** `RTCMTLVideoView` rather than borrowing the one on
/// screen: an `RTCVideoTrack` takes several renderers, so the PiP window attaches to the
/// same track as a second renderer instead of pulling the tile's view out from under
/// SwiftUI.
@MainActor
final class CallPiPController: NSObject {
    /// Where the outcome is reported. Nothing here fails silently: a window that never
    /// appeared is indistinguishable from one never asked for, and the delegate's error
    /// is the only place a reason exists.
    var onLog: ((String) -> Void)?

    private var controller: AVPictureInPictureController?
    private var callViewController: AVPictureInPictureVideoCallViewController?
    private var renderer: RTCMTLVideoView?
    private weak var track: RTCVideoTrack?

    var isActive: Bool { controller?.isPictureInPictureActive ?? false }
    var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
    var isArmed: Bool { controller != nil }

    /// Prepares the PiP window for a call: it appears when the app is backgrounded and
    /// shows `track`, growing out of `sourceView`.
    ///
    /// Idempotent for the same track and view, because callers arm it from wherever the
    /// two become available — the tile's view and the remote track arrive at different
    /// moments and neither is guaranteed to be second.
    @discardableResult
    func arm(track: RTCVideoTrack, sourceView: UIView) -> Bool {
        guard isSupported else {
            onLog?("PiP is not supported on this device")
            return false
        }
        guard !isArmed else { return true }

        let callViewController = AVPictureInPictureVideoCallViewController()
        callViewController.preferredContentSize = CGSize(width: 360, height: 640)

        let renderer = RTCMTLVideoView(frame: callViewController.view.bounds)
        renderer.videoContentMode = .scaleAspectFill
        renderer.translatesAutoresizingMaskIntoConstraints = false
        callViewController.view.addSubview(renderer)
        NSLayoutConstraint.activate([
            renderer.leadingAnchor.constraint(equalTo: callViewController.view.leadingAnchor),
            renderer.trailingAnchor.constraint(equalTo: callViewController.view.trailingAnchor),
            renderer.topAnchor.constraint(equalTo: callViewController.view.topAnchor),
            renderer.bottomAnchor.constraint(equalTo: callViewController.view.bottomAnchor),
        ])
        track.add(renderer)

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: callViewController
        )
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        // The system starts it when the app leaves; this is the flag that says the call
        // video is the user's primary focus, which is what a call's video is.
        controller.canStartPictureInPictureAutomaticallyFromInline = true

        self.callViewController = callViewController
        self.controller = controller
        self.renderer = renderer
        self.track = track

        onLog?("PiP armed (supported=\(isSupported), possible=\(controller.isPictureInPicturePossible))")
        return true
    }

    /// Closes the window while keeping the arrangement armed.
    ///
    /// Returning to the app has to take the window down — otherwise it floats over the
    /// call screen showing the same call twice — but it must not disarm, because the call
    /// still has video and the system should open the window again the next time the app
    /// is left. Measured on 2026-09-19: nothing dismisses it on the app's behalf, so an
    /// armed arrangement left alone keeps its window over the app indefinitely.
    func closeWindow() {
        guard let controller, controller.isPictureInPictureActive else { return }
        controller.stopPictureInPicture()
        onLog?("PiP window closed on return to the app")
    }

    /// Ends the PiP arrangement — the call is over, or there is no video to show.
    ///
    /// The header is explicit that a video-call content source is for the duration of a
    /// call and that the content source must be cleared afterwards, so this drops the
    /// whole controller rather than only stopping the window.
    func disarm() {
        if let controller, controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        }
        teardown()
    }

    private func teardown() {
        if let renderer {
            track?.remove(renderer)
            renderer.removeFromSuperview()
        }
        renderer = nil
        track = nil
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
            self.onLog?("PiP stopped")
            self.teardown()
        }
    }

    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: any Error
    ) {
        Task { @MainActor in
            self.onLog?("PiP failed to start: \(error.localizedDescription)")
            self.teardown()
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
