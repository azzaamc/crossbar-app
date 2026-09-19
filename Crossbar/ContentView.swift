import SwiftUI

/// The app root.
///
/// Owns the one call session and shows whichever screen that state calls for, so no
/// screen has to know how another is reached — and so there is exactly one place that
/// decides what "in a call" looks like.
struct ContentView: View {
    @StateObject private var session = CallSession()

    #if DEBUG
    /// Set by `CROSSBAR_PROBE_AUTOSHOW=1`.
    ///
    /// The instruments' own launch gates cannot fire until their screen is on screen,
    /// and that screen sits behind a tap in the contacts toolbar — which is exactly
    /// what a run nobody can stand next to the phone cannot do. This is how the
    /// signalling instrument gets driven without a hand.
    ///
    ///   … -e '{"CROSSBAR_PROBE_AUTOSHOW":"1"}'
    ///
    /// Set by `onAppear` below, and deliberately not in the `@State` initialiser: a
    /// `fullScreenCover` whose binding is already true when the view is inserted is not
    /// presented at all — the presentation wants a change — and not from the load task
    /// either, which is cancelled when the phase switch changes the view's identity.
    /// Both were tried on 2026-09-19 and both presented nothing, which reads exactly like
    /// the variable never being delivered.
    @State private var showProbe = false
    #endif

    var body: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView("Connecting to Family Call…")

            case .needsLogin:
                ContentUnavailableView {
                    Label("Sign in to the family network",
                          systemImage: "person.badge.key.fill")
                } description: {
                    Text(session.tailnetLoginURL == nil
                         ? "This app carries the family network itself, so nothing else has to be "
                         + "installed. It is starting up, and the sign-in page will appear here "
                         + "as soon as it is ready."
                         : "Approve this device in the page that opens. The app carries on by "
                         + "itself once it is authorised.")
                } actions: {
                    if session.tailnetLoginURL != nil {
                        Button("Open the sign-in page") { session.node.openLoginPage() }
                            .buttonStyle(.borderedProminent)
                    }
                    if let url = session.tailnetLoginURL {
                        Text(url)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                }

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
        .task {
            await session.load()
        }
        #if DEBUG
        // The instruments, presented over whatever the product is showing. A debug
        // screen reachable only by tapping a toolbar item cannot be reached at all
        // when the phone is on a desk.
        .onAppear {
            if ProcessInfo.processInfo.environment["CROSSBAR_PROBE_AUTOSHOW"] == "1" {
                showProbe = true
            }
        }
        .fullScreenCover(isPresented: $showProbe) { ProbeView() }
        #endif
    }
}

// No `#Preview` here on purpose. Rendering this view starts the whole session — it
// authenticates, opens an event stream, and joins any call it is already part of — so
// a preview is not a harmless mock. One did exactly that on 2026-09-18: an Xcode
// preview running on the Mac authenticated through the same Tailscale identity, decided
// it was a participant in a live call, and joined it as a third member with no camera.
// The family member on the other end saw someone whose video never loaded. Previews
// belong on leaf views that take plain data, not on the root that owns the session.
