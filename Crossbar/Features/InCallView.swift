import SwiftUI

/// The call itself.
///
/// Everything the user can do here is routed through **CallKit**, not the API, so this screen
/// and the system's own call UI can never disagree about whether the microphone is muted or the
/// call has ended. That is why `end()` and `toggleMute()` live on the session rather than being
/// wired straight to the client.
///
/// On a video call the controls get out of the way, because the picture is what the screen is
/// for — but only once there is somebody's picture to watch, and never while a call is still
/// ringing, when the controls are all there is. A tap brings them back, and a screen reader is
/// told the same thing by the action on the video.
///
/// **Two screens live in here, and what decides between them is whether the call has a
/// picture.** With one it is the picture, filling the screen, controls over the bottom of it.
/// Without one it is the person the call is with, their name, and how long it has been going —
/// no frame, no placeholder, and nothing apologising for the absence of a camera. Starting
/// video mid-call is what moves a call from the second to the first, and it is one tap.
struct InCallView: View {
    @ObservedObject var session: CallSession

    @State private var showControls = true

    /// Whether the controls may slide into and out of place, or should simply be there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            if showsVideo {
                heading
                videoStage
            } else {
                audioStage
            }

            if showControls {
                controls
                    .padding(.bottom, Theme.Space.normal)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, Theme.Space.normal)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showControls)
    }

    // MARK: - The two screens

    /// Whether this call has a picture in it, which is what decides which screen it gets.
    ///
    /// Three separate things can put video in a call and any one of them is enough: it was
    /// placed or answered as a video call, the camera has been turned on since, or the far end
    /// has started sending. That last one is why this cannot be the call's kind on its own — a
    /// person on an audio call can turn their camera on, and the video layout is the only one
    /// that can show them. The rule matters most in the other direction, though: with none of
    /// the three there is no picture to make room for, and the audio screen makes room for
    /// nothing.
    private var showsVideo: Bool {
        session.isVideoCall || session.isCameraEnabled || session.hasRemoteVideo
    }

    /// The picture, when there is one.
    private var videoStage: some View {
        CallVideoGrid(
            signal: session.signal,
            localTrack: session.media.videoTrack,
            // A disabled track renders black, and a black tile cannot be told from a
            // frozen one — the local preview has to be told which it is showing.
            localCameraOff: !session.isCameraEnabled,
            // PiP grows out of the tile the user is watching, and the session arms it
            // while this screen is in front — which is the only time it can be armed.
            onRemoteViewReady: { session.noteRemoteTileView($0) }
        )
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        .accessibilityAction(named: "Show call controls") { showControls = true }
    }

    /// An audio call, which has no picture and does not pretend to have one.
    ///
    /// This used to be the video screen with a camera-off tile in it, and that reads as a video
    /// call that failed rather than as an audio call: a black rectangle where a face ought to
    /// be, in a frame built to hold one, with a caption underneath apologising for it. There is
    /// no frame here at all. Nothing is being sent and nothing is being received, so the only
    /// thing there is to show is who the call is with.
    ///
    /// The initial appears only when there is one other person, and nothing is drawn when there
    /// are more: a circle with one of three names in it is picking one of them, and the heading
    /// underneath names everybody anyway.
    private var audioStage: some View {
        VStack(spacing: Theme.Space.normal) {
            if others.count == 1, let person = others.first {
                Avatar(
                    initial: Avatar.initial(of: person),
                    diameter: Theme.Avatar.call,
                    isProminent: true
                )
            }
            heading
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Who, and what is happening

    /// The people on the call, and what is happening to it.
    ///
    /// The names are the heading rather than the status: "Calling…" as a title says the same
    /// thing twice, and somebody glancing at the screen wants to know *who* first.
    private var heading: some View {
        VStack(spacing: Theme.Space.hairline) {
            Text(others.isEmpty ? "Calling…" : others.formatted(.list(type: .and)))
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            HStack(spacing: Theme.Space.hairline) {
                if isConnected, let answered = session.phase.call?.answeredAt {
                    // How long the call has been up is the one number somebody looks for, and
                    // it is a fact the record already has — no counter of our own to drift
                    // away from it.
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Reading.duration(from: answered, to: context.date.ISO8601Format()) ?? status)
                    }
                } else {
                    Text(status)
                }

                if session.eventsDown {
                    Text("·")
                    Label("Reconnecting", systemImage: "exclamationmark.triangle.fill")
                }
            }
            .font(.footnote)
            .foregroundStyle(session.eventsDown ? Color.orange : Color.secondary)
        }
        .padding(.top, Theme.Space.snug)
        .accessibilityElement(children: .combine)
    }

    /// Everyone on the call except the user. For a call here that is usually one name;
    /// when it is more, all of them, because "Call with Mum" is wrong when Dad is there too.
    private var others: [String] {
        guard let call = session.phase.call else { return [] }
        return (call.participants ?? [])
            .map(\.userId)
            .filter { $0 != session.me?.id }
            .map { session.displayName(for: $0) }
    }

    private var isConnected: Bool {
        if case .inCall = session.phase { return true }
        return false
    }

    private var status: String {
        switch session.phase {
        case .outgoing: return "Ringing…"
        case .inCall: return others.count > 1 ? "Connected · \(others.count + 1) people" : "Connected"
        default: return ""
        }
    }

    // MARK: - Controls

    /// Whether the controls may get out of the way at all.
    ///
    /// Only ever offered by the video stage, and only on a call with somebody else on it. An
    /// audio call has nothing to reveal behind its controls, so its screen does not hide them
    /// and never asks this. What it guards is a video call that is still ringing: the controls
    /// are the whole of the screen there, and a tap that made them vanish would be taking away
    /// the only thing there is.
    private var canHideControls: Bool { !others.isEmpty && isConnected }

    private func toggleControls() {
        guard canHideControls else { return }
        showControls.toggle()
    }

    /// The controls at whichever size fits the screen.
    ///
    /// The full row — a video call's, at five buttons — wants about 370 points of width, which
    /// a phone on its side, or a small one, does not have. A control past the edge of the
    /// screen is a control the user cannot reach, and on a call screen that is the one failure
    /// that matters, so the row steps down to a tighter one rather than being clipped.
    ///
    /// An audio call is one button lighter than a video call rather than two: there is nothing
    /// to flip while nothing is being sent, and the camera button stays, because turning an
    /// audio call into a video one is something it can do.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(spacing: Theme.Space.normal, diameter: Theme.Control.regular)
            controlRow(spacing: Theme.Space.tight, diameter: Theme.Control.compact)
        }
    }

    private func controlRow(spacing: CGFloat, diameter: CGFloat) -> some View {
        HStack(spacing: spacing) {
            control(
                session.isMuted ? "mic.slash.fill" : "mic.fill",
                session.isMuted ? "Unmute" : "Mute",
                diameter: diameter,
                isActive: session.isMuted
            ) { session.toggleMute() }

            // One control in both kinds of call, because it is one question and now one state:
            // whether this device is sending video. An audio call starts with the camera off
            // and this button turns the call into a video one; a video call starts with it on
            // and the same button stops it. Nothing is renegotiated either way — see
            // `CallSession.connect` — so switching is one tap, which is how the far end's own
            // camera button behaves too.
            //
            // Highlighted only while a *video* call has its camera off, which is a state worth
            // noticing. An audio call's camera is off because that is what the call is, and a
            // button flagging that would be flagging the call the person asked for.
            control(
                session.isCameraEnabled ? "video.slash.fill" : "video.fill",
                session.isCameraEnabled ? "Camera off" : "Start video",
                diameter: diameter,
                isActive: session.isVideoCall && !session.isCameraEnabled
            ) { session.toggleCamera() }

            // Flip only while there are two cameras' worth of choice to make: a flip button for
            // a camera that is not running is a control for something the call is not doing.
            if session.isCameraEnabled {
                control("camera.rotate.fill", "Flip", diameter: diameter) { session.switchCamera() }
            }

            control(
                "speaker.wave.2.fill",
                "Speaker",
                diameter: diameter,
                isActive: session.isSpeakerOn
            ) { session.toggleSpeaker() }

            control("phone.down.fill", "End", diameter: diameter, isDestructive: true) {
                session.end()
            }
        }
    }

    private func control(
        _ symbol: String,
        _ label: String,
        diameter: CGFloat,
        isActive: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: Theme.Space.hairline) {
                Image(systemName: symbol)
                    .font(.system(size: diameter * 0.4, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .frame(width: diameter, height: diameter)
                    .background(
                        isDestructive ? AnyShapeStyle(.red)
                            : isActive ? AnyShapeStyle(.tint.opacity(0.22))
                            : AnyShapeStyle(.thinMaterial),
                        in: Circle()
                    )
                    .foregroundStyle(isDestructive ? .white : .primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(minWidth: diameter)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        // A control that changes something says what it is set to, so the state is not
        // carried by a tint the screen reader cannot see.
        .accessibilityValue(isDestructive ? "" : (isActive ? "on" : "off"))
    }
}
