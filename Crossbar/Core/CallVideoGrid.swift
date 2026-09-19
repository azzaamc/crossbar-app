import Combine
import SwiftUI
import WebRTC

/// One video tile: the track, and a caption over it.
///
/// The frame is the caller's business — the product grid sizes tiles by aspect ratio,
/// the signalling instrument gives each a fixed height — so this only draws.
///
/// Note what a black tile does and does not mean: no frames have been *decoded*. It
/// cannot mean "capture stopped", because `RTCMTLVideoView` keeps its last rendered
/// frame after the track detaches, so a frozen picture and a live one are
/// indistinguishable here. Prove liveness some other way — a frame counter, the status
/// bar's privacy indicator, or inbound RTP.
struct VideoTile: View {
    let track: RTCVideoTrack?
    let caption: String

    /// Set when the peer's camera is off: the tile says so instead of drawing the last
    /// frame it received, which would look like a working call with a frozen picture —
    /// the exact confusion this project has paid for twice.
    var cameraOff = false

    /// The remote tile's view, for a caller that needs one to animate PiP out of.
    var onViewReady: ((RTCMTLVideoView) -> Void)?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if cameraOff {
                ZStack {
                    Rectangle().fill(.black)
                    Image(systemName: "video.slash.fill")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                RTCVideoSurface(track: track, onViewReady: onViewReady)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text(cameraOff ? "\(caption) · camera off" : caption)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
    }
}

/// The call's video: this device's capture and every remote peer's, handed to the stage.
///
/// **Observes the signalling client directly.** A nested `ObservableObject` does not
/// republish, so a view that reads remote tracks through some outer model never learns
/// that one arrived — which is exactly how the first real call rendered its local tile
/// and nothing else, while the log plainly showed the remote video track had been
/// received. Any view showing video must own or directly observe the client.
///
/// Peers are ordered by id so tiles do not swap places as the dictionary rehashes, which
/// is also what makes "the first remote" a stable answer for the arrangement.
struct CallVideoGrid: View {
    @ObservedObject var signal: MiroTalkSignalClient
    let localTrack: RTCVideoTrack?

    /// Whether the user's own camera is on; see `CallStage.localCameraOff`.
    var localCameraOff = false

    /// The remote tile's view, handed to whoever starts Picture-in-Picture: the window
    /// animates out of the tile the user was watching, so it has to be a real view.
    var onRemoteViewReady: ((RTCMTLVideoView) -> Void)?

    /// Only peers that have sent video appear here, as they always have: a tile for someone
    /// whose camera has never arrived would be an empty rectangle pretending to be a
    /// participant.
    private var peers: [StagePeer] {
        signal.remoteVideo.keys.sorted().map { peerID in
            StagePeer(
                id: peerID,
                track: signal.remoteVideo[peerID],
                // The name arrives in `addPeer`. A socket id is not who is on the
                // call, so it is only ever the fallback.
                caption: signal.remoteNames[peerID] ?? String(peerID.prefix(6)),
                cameraOff: signal.remoteVideoOff.contains(peerID)
            )
        }
    }

    var body: some View {
        CallStage(
            peers: peers,
            localTrack: localTrack,
            localCameraOff: localCameraOff,
            onRemoteViewReady: onRemoteViewReady
        )
    }
}
