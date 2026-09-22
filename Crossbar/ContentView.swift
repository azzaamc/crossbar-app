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
                LaunchView()

            case .needsLogin:
                ContentUnavailableView {
                    Label("Approve this device", systemImage: "person.badge.key.fill")
                } description: {
                    Text(session.tailnetLoginURL == nil
                         ? "Crossbar is starting its connection. The sign-in page will appear "
                         + "here as soon as it is ready."
                         : "Your household's network has to recognise this device before "
                         + "Crossbar can reach it. Approve it in the page that opens, and the "
                         + "app carries on by itself.")
                } actions: {
                    if session.tailnetLoginURL != nil {
                        Button("Open the sign-in page") { session.node.openLoginPage() }
                            .buttonStyle(.borderedProminent)
                    }
                }

            case .ringing(let call):
                IncomingCallView(session: session, call: call)

            case .outgoing, .inCall:
                InCallView(session: session)

            case .ready:
                MainTabs(session: session)

            case .failed:
                // The same app, with the failure shown inside it rather than instead of it.
                // A whole screen of "can't reach the service" takes away the people somebody
                // opened it to call, and the one thing still worth doing — seeing whether
                // anyone is around.
                //
                // This is also how the app keeps a route to Settings. A refusal once named a
                // screen the app offered no way to reach, and which needed a button of its
                // own to fix; a tab bar cannot help but offer it. The service's own words for
                // why are not shown here — they belong in diagnostics.
                MainTabs(session: session)
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
    }
}

/// What the app shows while it works out whether it can reach anything.
///
/// The name, and a quiet sign of life. Deliberately not a spinner alone on white: the first
/// thing anybody sees should say what they opened, and the second should say it is working
/// rather than that it has stopped.
private struct LaunchView: View {
    var body: some View {
        VStack(spacing: Theme.Space.snug) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 46, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            Text("Crossbar")
                .font(.title3.weight(.semibold))
            ProgressView()
                .controlSize(.small)
                .padding(.top, Theme.Space.hairline)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Crossbar is connecting")
    }
}

// No `#Preview` here on purpose. Rendering this view starts the whole session — it
// authenticates, opens an event stream, and joins any call it is already part of — so
// a preview is not a harmless mock. One did exactly that on 2026-09-18: an Xcode
// preview running on the Mac authenticated through the same Tailscale identity, decided
// it was a participant in a live call, and joined it as a third member with no camera.
// The family member on the other end saw someone whose video never loaded. Previews
// belong on leaf views that take plain data, not on the root that owns the session.
