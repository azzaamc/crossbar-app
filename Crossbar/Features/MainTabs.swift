import SwiftUI

/// The three places Crossbar has.
///
/// People, Recents, Settings — a tab bar rather than anything cleverer, because there are
/// three of them and each is one tap from the others. Nothing about the server lives at this
/// level: which deployment this device belongs to is a fact about how the app connects, not a
/// place to visit, and the screen that shows it sits inside Settings with the rest of the
/// plumbing.
///
/// The connection's state is shown *inside* these screens rather than instead of them. An app
/// that replaces itself with a failure screen when the service is unreachable has taken away
/// the people somebody opened it to call — and the one thing they might still usefully do,
/// which is see who was around — along with it.
struct MainTabs: View {
    @ObservedObject var session: CallSession

    var body: some View {
        TabView {
            NavigationStack {
                PeopleView(session: session)
            }
            .tabItem { Label("People", systemImage: "person.2.fill") }

            NavigationStack {
                RecentsView(session: session)
            }
            .tabItem { Label("Recents", systemImage: "clock.fill") }

            SettingsView(session: session)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
    }
}
