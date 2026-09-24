import SwiftUI

/// The deployment moved under this device.
///
/// Shown when the server says it is reached differently from how this device was set up — an
/// administrator switched it between its private and public configurations. A screen rather than
/// a notice, because there is nothing useful underneath it: this device is dialling an address
/// that belonged to a deployment which is no longer there, so every screen behind this one is
/// showing what that dead address last said.
///
/// What the person has to do differs by where the server went, and only the server can say where
/// that is — which is why `CallSession.serverMovedTo` carries the mode rather than a flag.
/// Tailscale is a second and separate thing from the enrollment code, and the private case needs
/// both: the code is what points the app at the server, and the tailnet is what carries the
/// request to it.
struct ServerMovedView: View {
    let mode: ConnectionMode
    var onSetUpAgain: () -> Void

    @State private var confirming = false

    var body: some View {
        ContentUnavailableView {
            Label("Your Crossbar has moved", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text(message)
        } actions: {
            Button("Set up again") { confirming = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("moved.setUpAgain")
        }
        .confirmationDialog("Set this device up again?", isPresented: $confirming,
                            titleVisibility: .visible) {
            Button("Set up again", role: .destructive) { onSetUpAgain() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The same sentence the Settings screen uses for the same act, because it is the
            // same act: the key is deleted and the administrator has to invite the device again.
            Text("The key this device holds is deleted and cannot be recovered. Your administrator "
                 + "will need to invite it again.")
        }
    }

    private var message: String {
        switch mode {
        case .privateNetwork:
            return "Your administrator changed how Crossbar is reached, and this server is now on "
                 + "a private network. You will need the new enrollment code they send you, and to "
                 + "approve this device in Tailscale when the app asks."
        case .publicServer:
            return "Your administrator changed how Crossbar is reached, and this server is now on "
                 + "the public internet. You will need the new enrollment code they send you."
        }
    }
}

#Preview("Moved to a private network") {
    ServerMovedView(mode: .privateNetwork) {}
}

#Preview("Moved to the public internet") {
    ServerMovedView(mode: .publicServer) {}
}
