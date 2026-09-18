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
    @State private var showProbe = false
    #endif

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
        .task {
            await session.load()
            #if DEBUG
            // Buttons on a device cannot be pressed from here, so the CallKit path gets
            // a gated way in that rings nobody. See `runCallKitSelfTest`.
            if ProcessInfo.processInfo.environment["CROSSBAR_CALLKIT_SELFTEST"] == "1" {
                session.runCallKitSelfTest()
            }
            // Same reasoning, and the same shape. The embedded node is what lets this
            // app reach the tailnet without the Tailscale app, so measuring it has to
            // be possible on a device nobody can tap:
            //   xcrun devicectl device process launch … -e '{"CROSSBAR_TAILSCALE_AUTOSTART":"1"}'
            // Started in its own task so bring-up does not wait on the session load
            // above, which reaches the network and can take seconds.
            if ProcessInfo.processInfo.environment["CROSSBAR_TAILSCALE_AUTOSTART"] == "1" {
                Task { await TailscaleProbe.shared.start() }
            }
            // Same reasoning again: a gated instrument is only gated if it is on screen.
            if ProcessInfo.processInfo.environment["CROSSBAR_PROBE_AUTOSHOW"] == "1" {
                showProbe = true
            }
            #endif
        }
        #if DEBUG
        // The instruments, presented over whatever the product is showing. A debug
        // screen reachable only by tapping a toolbar item cannot be reached at all
        // when the phone is on a desk.
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
