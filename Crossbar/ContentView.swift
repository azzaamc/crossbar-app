import SwiftUI

/// The app root.
///
/// Owns the one call session and shows whichever screen that state calls for, so no
/// screen has to know how another is reached — and so there is exactly one place that
/// decides what "in a call" looks like.
///
/// It also decides whether there is anything to show at all: until someone has said
/// whether this device belongs to a household's own network or to a server at a hostname,
/// the app has no route to dial and asks. That answer is read here rather than through the
/// session, because it is the thing that decides whether the session has anything to load.
struct ContentView: View {
    @StateObject private var session = CallSession()

    /// Seeded from what is stored, then kept here: the onboarding screen is the only thing
    /// that changes it while this view is on screen, and it says so through `onChoose`.
    @State private var mode = AppSettings.connectionMode

    /// Whether Settings is up, from the failure screen.
    ///
    /// Everywhere else Settings is reached from the contacts toolbar, which exists only once
    /// the session is up. When it is not, this is the only route to the screen holding the
    /// address and the enrolment code — which is where the refusal message points.
    @State private var showSettings = false

    var body: some View {
        Group {
            if mode == nil {
                // Nothing is dialled before this choice is made. The mode is what decides
                // whether this app carries its own network, so a load that ran first would be
                // choosing one of the two deployments on the person's behalf — the guess this
                // screen exists to avoid.
                OnboardingView { mode = $0 }
            } else {
                product
            }
        }
    }

    /// What the product shows, once there is a route to reach it by.
    private var product: some View {
        Group {
            switch session.phase {
            case .loading:
                ProgressView("Connecting…")

            case .needsLogin:
                ContentUnavailableView {
                    Label("Sign in to the network",
                          systemImage: "person.badge.key.fill")
                } description: {
                    Text(session.tailnetLoginURL == nil
                         ? "This app carries its own network connection, so nothing else has "
                         + "to be installed. It is starting up, and the sign-in page will "
                         + "appear here as soon as it is ready."
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
                    Label("Can't reach the service", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(reason)
                } actions: {
                    Button("Try again") { Task { await session.load() } }
                        .buttonStyle(.borderedProminent)
                    // The way out of a state this screen cannot fix by retrying.
                    //
                    // A device that holds an address but no key gets a refusal from the
                    // server, and the refusal tells it to paste an enrolment code in
                    // Settings — which, without this button, was a screen the message named
                    // and the app offered no route to. Retrying cannot help: the answer will
                    // be the same until the address or the device changes, and both of those
                    // live in Settings. Measured 2026-09-21, on the way into the first public
                    // deployment, by doing exactly that.
                    Button("Settings") { showSettings = true }
                }

            case .ringing(let call):
                IncomingCallView(session: session, call: call)

            case .outgoing, .inCall:
                InCallView(session: session)

            case .ready:
                ContactsView(session: session)
            }
        }
        // Loaded once per launch, and again whenever the connection changes — which is why
        // the mode is the key rather than something read inside. A load is how a route is
        // taken: a node brought up for the private mode, a direct dial for a server, and
        // switching between them has to re-dial everything either way. A call that arrives
        // while this is in flight is not lost: the stream carries it, and `/api/bootstrap`
        // re-reports anything already ringing.
        .task(id: mode) {
            await session.load()
        }
        .sheet(isPresented: $showSettings) { SettingsView(session: session) }
    }
}

// No `#Preview` here on purpose. Rendering this view starts the whole session — it
// authenticates, opens an event stream, and joins any call it is already part of — so
// a preview is not a harmless mock. One did exactly that on 2026-09-18: an Xcode
// preview running on the Mac authenticated through the same Tailscale identity, decided
// it was a participant in a live call, and joined it as a third member with no camera.
// The family member on the other end saw someone whose video never loaded. Previews
// belong on leaf views that take plain data, not on the root that owns the session.
