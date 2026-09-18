#if DEBUG
import SwiftUI
import WebRTC

/// A Metal-backed surface for any `RTCVideoTrack` — local capture or a remote peer's.
///
/// `RTCCameraPreviewView` no longer exists in the SDK; the supported path is an
/// `RTCMTLVideoView` registered as an `RTCVideoRenderer` on the track, which is what
/// this does. It was named `RTCLocalPreview` and lived in the seam probe while local
/// preview was the only thing anyone rendered; it now serves the product call path
/// too, so it lives on its own and takes whichever track it is given.
///
/// One caveat is load-bearing for anyone reading a screenshot: **the view keeps its
/// last rendered frame after the track is detached**, so a frozen picture and a live
/// one are indistinguishable. Prove capture is live some other way — a frame counter,
/// or the status-bar privacy indicator.
struct RTCVideoSurface: UIViewRepresentable {
    let track: RTCVideoTrack?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView()
        view.videoContentMode = .scaleAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        // Re-attaching on every update would tear the renderer down and rebuild it;
        // identity comparison also releases the previous track when the view is
        // recycled for a different peer.
        guard context.coordinator.attached !== track else { return }
        context.coordinator.attached?.remove(view)
        track?.add(view)
        context.coordinator.attached = track
    }

    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) {
        coordinator.attached?.remove(view)
        coordinator.attached = nil
    }

    final class Coordinator {
        var attached: RTCVideoTrack?
    }
}
#endif
