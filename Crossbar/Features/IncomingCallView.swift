import SwiftUI

/// An incoming call.
///
/// Deliberately has **no answer button**. The call is reported to CallKit and answering
/// belongs to the system's call UI: an app that answers behind CallKit's back leaves the
/// system still showing an incoming call that is already connected, and the ringing UI
/// stays up over it. This screen mirrors the state so the app is not blank behind the
/// system UI, and Decline routes through CallKit's end action like every other control.
struct IncomingCallView: View {
    @ObservedObject var session: CallSession
    let call: FamilyCall

    var body: some View {
        VStack(spacing: 14) {
            Spacer()

            Image(systemName: "phone.arrow.down.left")
                .font(.system(size: 52))
                .foregroundStyle(.tint)

            Text(session.displayName(for: call.callerId))
                .font(.largeTitle.weight(.bold))
                .multilineTextAlignment(.center)

            Text("Incoming call")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Answer from the call banner.")
                .font(.footnote)
                .foregroundStyle(.tertiary)

            Spacer()

            Button(role: .destructive) {
                session.decline()
            } label: {
                Label("Decline", systemImage: "phone.down.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }
}
