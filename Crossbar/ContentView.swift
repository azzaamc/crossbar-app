import SwiftUI

/// The app root.
///
/// Owns the one call session and shows whichever screen that state calls for, so no
/// screen has to know how another is reached — and so there is exactly one place that
/// decides what "in a call" looks like.
struct ContentView: View {
    @StateObject private var session = CallSession()

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView("Connecting to Family Call…")

            case .failed(let reason):
                ContentUnavailableView {
                    Label("Can't reach Family Call", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Try again") { Task { await session.load() } }
                        .buttonStyle(.borderedProminent)
                }

            case .ringing(let call):
                IncomingCallView(session: session, call: call)

            case .outgoing, .inCall:
                InCallView(session: session)

            case .ready:
                ContactsView(session: session)
            }
        }
        // Loaded once per launch. A call that arrives while this is in flight is not
        // lost: the stream carries it, and `/api/bootstrap` re-reports anything already
        // ringing.
        .task { await session.load() }
    }
}

#Preview {
    ContentView()
}
