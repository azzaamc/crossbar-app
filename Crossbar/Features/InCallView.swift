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
struct InCallView: View {
    @ObservedObject var session: CallSession

    @State private var showControls = true

    /// Whether the controls may slide into and out of place, or should simply be there.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            heading

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

            if showControls {
                controls
                    .padding(.bottom, Theme.Space.normal)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.horizontal, Theme.Space.normal)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: showControls)
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

    /// Everyone on the call except the user. For a household call that is usually one name;
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
    /// Only on a call with somebody else's picture on it. With no remote video the controls
    /// are the whole of the screen, and one that hides when it is the only thing there is a
    /// control the user has to hunt for.
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
    /// An audio call drops the two camera buttons, which are not tight fits but controls for
    /// something that call cannot do: `kind` came back with the call, so the row knows.
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

            if session.isVideoCall {
                control(
                    session.isCameraEnabled ? "video.fill" : "video.slash.fill",
                    session.isCameraEnabled ? "Camera off" : "Camera on",
                    diameter: diameter,
                    isActive: !session.isCameraEnabled
                ) { session.toggleCamera() }

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
