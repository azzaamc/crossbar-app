import SwiftUI

/// The call itself.
///
/// Everything the user can do here is routed through **CallKit**, not the API, so this
/// screen and the system's own call UI can never disagree about whether the microphone
/// is muted or the call has ended. That is why `end()` and `toggleMute()` live on the
/// session rather than being wired straight to the client.
struct InCallView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        VStack(spacing: 12) {
            VStack(spacing: 2) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 12)

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

            if session.eventsDown {
                Text("Lost the connection to the service — status may be out of date.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
            }

            controls
                .padding(.bottom, 16)
        }
        .padding(.horizontal)
    }

    /// The controls at whichever size fits the screen.
    ///
    /// Five buttons at the comfortable size want about 370 points of width, which a phone
    /// on its side — or a small one — does not have. A control past the edge of the screen
    /// is a control the user cannot reach, and on a call screen that is the one failure
    /// that matters, so the row steps down to a tighter one rather than being clipped.
    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlRow(spacing: 16, diameter: 52)
            controlRow(spacing: 8, diameter: 40)
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

            control(
                session.isCameraEnabled ? "video.fill" : "video.slash.fill",
                session.isCameraEnabled ? "Camera off" : "Camera on",
                diameter: diameter,
                isActive: !session.isCameraEnabled
            ) { session.toggleCamera() }

            control("camera.rotate.fill", "Flip", diameter: diameter) { session.switchCamera() }

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

    /// Everyone on the call except the user. For a household call that is usually one
    /// name; when it is more, all of them, because "Call with Mum" is wrong when Dad is
    /// there too.
    private var others: [String] {
        guard let call = session.phase.call else { return [] }
        return (call.participants ?? [])
            .map(\.userId)
            .filter { $0 != session.me?.id }
            .map { session.displayName(for: $0) }
    }

    private var title: String {
        others.isEmpty ? "Calling…" : others.formatted(.list(type: .and))
    }

    private var status: String {
        switch session.phase {
        case .outgoing: "Ringing…"
        case .inCall: others.count > 1 ? "Connected · \(others.count + 1) people" : "Connected"
        default: ""
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
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.title3)
                    .frame(width: diameter, height: diameter)
                    .background(
                        isDestructive ? AnyShapeStyle(.red)
                            : isActive ? AnyShapeStyle(.tint.opacity(0.25))
                            : AnyShapeStyle(.thinMaterial),
                        in: Circle()
                    )
                    .foregroundStyle(isDestructive ? .white : .primary)
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
