import SwiftUI
import WebRTC

/// Space between the stage's edge and anything docked against it.
private let stageInset: CGFloat = 10

/// Space between tiles, matching the gap the product grid has always used.
private let tileGap: CGFloat = 8

/// Which corner of the stage the local preview is docked in.
///
/// A corner rather than a free position: the preview deliberately sits over someone else's
/// picture, and one left wherever the finger stopped ends up parked over the face it was
/// dragged next to. Snapping on release is what makes "move it out of the way" leave a tidy
/// screen behind, and it is why the drag never needs a saved coordinate.
enum StageCorner: CaseIterable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing

    var isLeading: Bool { self == .topLeading || self == .bottomLeading }
    var isTop: Bool { self == .topLeading || self == .topTrailing }

    /// The corner nearest a point. The whole rule is which half of the stage the tile
    /// landed in, compared at the tile's own centre so it lands where it looked like it
    /// would — not at the touch point, which is where the finger is rather than where the
    /// tile is.
    static func nearest(to center: CGPoint, in stage: CGSize) -> StageCorner {
        switch (center.x < stage.width / 2, center.y < stage.height / 2) {
        case (true, true): return .topLeading
        case (false, true): return .topTrailing
        case (true, false): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }
}

/// One remote peer as the stage draws them.
///
/// A plain value rather than the signalling client itself, so the arrangement can be read
/// and changed without knowing anything about signalling: `CallVideoGrid` is the one that
/// observes the client and builds these.
struct StagePeer: Identifiable {
    let id: String
    let track: RTCVideoTrack?
    let caption: String
    let cameraOff: Bool
}

/// The call's video, composed for however many people are on it.
///
/// The arrangement is fixed for a given number of participants and never scrolls. A call
/// where someone is only visible after scrolling is a call where the user misses them, and
/// a scrolling stage also moves the one tile Picture-in-Picture is anchored to.
///
/// The rule, counting remotes (everyone but the user):
///
/// - **none** — nothing has arrived yet, so the local capture holds the stage.
/// - **one** — they fill the stage, and the local capture becomes a small draggable corner
///   overlay. This is what a call is most of the time.
/// - **two** — two columns, each the full height of the stage. That is as large as two
///   faces can be at once; stacking them as rows would halve each tile's height and crop
///   more of each face in a portrait frame.
/// - **three or more** — the first remote keeps the stage and the rest go in a short strip
///   along the bottom. Four equal quarters of a phone screen is four tiles showing four
///   people's foreheads; one large picture is the one the user can actually read, and the
///   strip keeps everyone else on screen at the same time without scrolling.
///
/// "First" is first in peer-id order everywhere, so the layout does not reshuffle when the
/// remote track dictionary rehashes.
struct CallStage: View {
    let peers: [StagePeer]
    let localTrack: RTCVideoTrack?

    /// Whether the user's own camera is on. A disabled track draws black, and a black tile
    /// cannot be told from a frozen one, so the tile has to be told which it is looking at.
    var localCameraOff = false

    /// The remote tile's view, for whoever arms Picture-in-Picture: the window grows out of
    /// it, so it has to be a real view in the hierarchy.
    var onRemoteViewReady: ((RTCMTLVideoView) -> Void)?

    var body: some View {
        GeometryReader { geo in
            ZStack {
                arrangement(in: geo.size)
                // Drawn after the arrangement, so the local preview is never behind anyone
                // else's video. With no remote video at all it is not drawn: it is already
                // the stage.
                if !peers.isEmpty {
                    LocalPreview(track: localTrack, cameraOff: localCameraOff)
                }
            }
        }
        // Black behind the tiles, so a stage with a letterboxed picture in it still reads
        // as a stage rather than as the app's background.
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func arrangement(in stage: CGSize) -> some View {
        if peers.isEmpty {
            // An outgoing call on its way to being answered: the local capture is the only
            // picture there is.
            VideoTile(track: localTrack, caption: "You", cameraOff: localCameraOff)
        } else if peers.count == 1 {
            tile(peers[0])
        } else if peers.count == 2 {
            HStack(spacing: tileGap) {
                ForEach(peers) { tile($0) }
            }
        } else {
            VStack(spacing: tileGap) {
                tile(peers[0])
                    .frame(maxHeight: .infinity)
                HStack(spacing: tileGap) {
                    ForEach(peers.dropFirst()) { tile($0) }
                }
                .frame(height: stripHeight(in: stage))
            }
        }
    }

    private func tile(_ peer: StagePeer) -> some View {
        VideoTile(
            track: peer.track,
            caption: peer.caption,
            cameraOff: peer.cameraOff,
            // Only the tile Picture-in-Picture grows out of is handed a view: `arm` watches
            // that view's layout frame and visibility, and the window would be seen growing
            // out of a strip tile a third of the size.
            onViewReady: peer.id == pipPeerID ? onRemoteViewReady : nil
        )
    }

    /// The tile the Picture-in-Picture window grows out of: the first remote, which is the
    /// one holding the stage — or, when that peer's camera is off and their tile therefore
    /// draws no surface at all, the first tile that does. That is the same view the old
    /// grid effectively handed over, and `CallSession.armPiP` needs one that exists.
    private var pipPeerID: String? {
        (peers.first(where: { !$0.cameraOff }) ?? peers.first)?.id
    }

    /// A face stays a face at a quarter of the stage's height; anything taller starts
    /// taking the stage from the picture the user is actually watching. The strip holds
    /// however many remotes there are and splits the width between them, so a fifth peer
    /// makes the strip narrower rather than making anyone scroll.
    private func stripHeight(in stage: CGSize) -> CGFloat {
        stage.height * 0.26
    }
}

/// The user's own capture: small, above the stage, and draggable between its four corners.
///
/// It is a child of the stage rather than of the screen, and that is load-bearing for the
/// brief: "the preview never covers the controls" is not a rule enforced here, because the
/// preview cannot leave the stage the controls sit below, however far it is dragged.
struct LocalPreview: View {
    let track: RTCVideoTrack?
    let cameraOff: Bool

    @State private var corner: StageCorner = .bottomTrailing
    /// How far the tile has been pulled away from that corner. Cleared on release, when the
    /// snap takes over, so the corner is the only state that survives a drag.
    @State private var drag: CGSize = .zero

    /// The snap is a nicety — the tile is already where the finger left it — so for anyone who
    /// has asked the system for less movement it simply appears in its corner instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            let stage = geo.size
            let size = previewSize(in: stage)
            // The picture is not hit-testable and the gesture lives on the container around
            // it, so no view inside the preview — the Metal video view included — can take
            // the touch the drag needs.
            ZStack {
                VideoTile(track: track, caption: "You", cameraOff: cameraOff)
                    .allowsHitTesting(false)
            }
                .frame(width: size.width, height: size.height)
                .contentShape(RoundedRectangle(cornerRadius: 12))
                .position(previewCentre(corner: corner, drag: drag, tile: size, stage: stage))
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { drag = $0.translation }
                        .onEnded { _ in
                            let landed = StageCorner.nearest(
                                to: previewDragged(corner: corner, drag: drag, tile: size, stage: stage),
                                in: stage
                            )
                            // Springing rather than jumping: the tile is in the user's hand
                            // when this runs, and the snap is the gesture's last act.
                            withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                                corner = landed
                                drag = .zero
                            }
                        }
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Your video")
                .accessibilityHint("Drag it to another corner")
        }
    }
}

// The preview's geometry, as arithmetic.
//
// Free functions rather than view methods for one reason: this is the part of the layout
// where being wrong is invisible in a screenshot — a clamp that lets the tile drift a few
// points past an edge — so it is written to be exercised without a running app.

/// Roughly a quarter of the stage's width — big enough to see what is being sent, small
/// enough not to become the subject — and never more than half its height, which is what
/// matters when the phone is on its side and the stage is short: 3/8 of the height is
/// exactly half of a 3:4 tile.
private func previewSize(in stage: CGSize) -> CGSize {
    let width = min(max(stage.width * 0.28, 72), max(stage.height * 0.375, 72))
    return CGSize(width: width, height: width * 4 / 3)
}

/// The corner's resting point for a tile of that size.
private func previewAnchor(corner: StageCorner, tile: CGSize, stage: CGSize) -> CGPoint {
    CGPoint(
        x: corner.isLeading
            ? stageInset + tile.width / 2
            : stage.width - stageInset - tile.width / 2,
        y: corner.isTop
            ? stageInset + tile.height / 2
            : stage.height - stageInset - tile.height / 2
    )
}

/// Where a drag has taken it, before clamping — what the snap is decided from, so a tile
/// pushed against an edge still snaps to the corner it was pushed toward.
private func previewDragged(
    corner: StageCorner, drag: CGSize, tile: CGSize, stage: CGSize
) -> CGPoint {
    let anchor = previewAnchor(corner: corner, tile: tile, stage: stage)
    return CGPoint(x: anchor.x + drag.width, y: anchor.y + drag.height)
}

/// Where the preview is actually drawn: the drag, clamped so it cannot leave the stage.
///
/// That clamp is the whole of "the preview never covers the controls". The controls are not
/// part of the stage, so a preview that cannot leave the stage cannot reach them, however
/// far it is dragged.
private func previewCentre(
    corner: StageCorner, drag: CGSize, tile: CGSize, stage: CGSize
) -> CGPoint {
    let moved = previewDragged(corner: corner, drag: drag, tile: tile, stage: stage)
    let margin = CGSize(width: tile.width / 2 + stageInset, height: tile.height / 2 + stageInset)
    return CGPoint(
        x: min(max(moved.x, margin.width), stage.width - margin.width),
        y: min(max(moved.y, margin.height), stage.height - margin.height)
    )
}
