import SwiftUI

/// An incoming call.
///
/// Deliberately has **no answer button**. The call is reported to CallKit and answering belongs
/// to the system's call UI: an app that answers behind CallKit's back leaves the system still
/// showing an incoming call that is already connected, and the ringing UI stays up over it.
/// This screen mirrors the state so the app is not blank behind the system UI, and Decline
/// routes through CallKit's end action like every other control.
///
/// It says as little as it can get away with for the same reason: the system is already showing
/// who is calling and offering to answer, so anything more here is the same news twice.
struct IncomingCallView: View {
    @ObservedObject var session: CallSession
    let call: Call

    private var caller: String { session.displayName(for: call.callerId) }

    private var initial: String {
        String(caller.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        VStack(spacing: Theme.Space.normal) {
            Spacer()

            Avatar(initial: initial, diameter: Theme.Avatar.detail, isProminent: true)

            VStack(spacing: Theme.Space.hairline) {
                Text(caller)
                    .font(.largeTitle.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Incoming \(call.kind == "audio" ? "call" : "video call")")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            Spacer()

            // The one instruction worth giving, because it is the one thing this screen cannot
            // do for them.
            Label("Answer from the call banner", systemImage: "phone.arrow.up.right")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Button(role: .destructive) {
                session.decline()
            } label: {
                Label("Decline", systemImage: "phone.down.fill")
                    .font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 34)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Decline the call from \(caller)")
            .padding(.horizontal, Theme.Space.loose)
            .padding(.bottom, Theme.Space.loose)
        }
    }
}
