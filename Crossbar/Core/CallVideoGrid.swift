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

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            RTCVideoSurface(track: track)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(caption)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(6)
        }
    }
}

/// The local capture and every remote peer's video, as tiles.
///
/// **Observes the signalling client directly.** A nested `ObservableObject` does not
/// republish, so a view that reads remote tracks through some outer model never learns
/// that one arrived — which is exactly how the first real call rendered its local tile
/// and nothing else, while the log plainly showed the remote video track had been
/// received. Any view showing video must own or directly observe the client.
///
/// Peers are ordered by id so tiles do not swap places as the dictionary rehashes.
struct CallVideoGrid: View {
    @ObservedObject var signal: MiroTalkSignalClient
    let localTrack: RTCVideoTrack?

    private var peerIDs: [String] { signal.remoteVideo.keys.sorted() }

    private var columns: [GridItem] {
        // One remote reads better large; more than one and a pair of columns keeps
        // every face visible at once, which is what a family call is for.
        peerIDs.count <= 1
            ? [GridItem(.flexible(), spacing: 8)]
            : [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 8) {
                VideoTile(track: localTrack, caption: "You")
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                ForEach(peerIDs, id: \.self) { peerID in
                    // The name arrives in `addPeer`. A socket id is not who is on the
                    // call, so it is only ever the fallback.
                    VideoTile(
                        track: signal.remoteVideo[peerID],
                        caption: signal.remoteNames[peerID] ?? String(peerID.prefix(6))
                    )
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                }
            }
        }
    }
}
