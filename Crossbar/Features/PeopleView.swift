import SwiftUI

/// Who you can call — the first screen, and the one that has to be right when somebody is
/// trying to reach their mother.
///
/// What is deliberately **not** here: which network carried the request, where the service
/// lives, or who the service thinks this device is. All three are real, none of them help
/// somebody ring their mother, and each is one screen away under Settings, where they answer
/// a question somebody has actually asked.
struct PeopleView: View {
    @ObservedObject var session: CallSession

    /// Whether the "set this device up again" confirmation is showing.
    @State private var confirmingSetUpAgain = false

    var body: some View {
        List {
            connection

            Section {
                ForEach(session.contacts) { contact in
                    PersonRow(
                        name: contact.displayName,
                        isOnline: contact.online,
                        status: presence(of: contact)
                    ) { video in
                        session.placeCall(to: contact, video: video)
                    }
                }
            } header: {
                if !session.contacts.isEmpty {
                    Text("On your Crossbar")
                }
            }
        }
        .navigationTitle("People")
        .refreshable { await session.refresh() }
        .overlay { emptyState }
        .confirmationDialog("Set this device up again?", isPresented: $confirmingSetUpAgain,
                            titleVisibility: .visible) {
            Button("Set up again", role: .destructive) {
                Task { await session.forgetServer() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // The same sentence the other two places that do this use, because it is the same
            // act and the same cost: the key is deleted, and only the administrator can let this
            // device back in.
            Text("The key this device holds is deleted and cannot be recovered. Your administrator "
                 + "will need to invite it again.")
        }
    }

    /// Where somebody is, in words.
    ///
    /// This is the one thing the person screen held that this list did not, and the screen is
    /// gone — a row here already rings somebody, so a page whose only other content was a way
    /// to ring them was a tap that bought nothing. What was worth keeping is this: the dot
    /// beside the name is the glanceable half, and this is the half that says *when*.
    ///
    /// Deliberately not called reachability, and not a statement about whether a call would
    /// work. A call rings their phone through a push whether or not Crossbar is open on it, so
    /// there is no state of theirs in which calling them fails to arrive. What being on
    /// Crossbar now tells you is the other thing: that they are likelier to pick up.
    private func presence(of contact: Contact) -> String {
        if contact.online { return "On Crossbar now" }
        if let ago = Reading.ago(contact.lastSeen) { return "Last seen \(ago)" }
        return "Not on Crossbar now"
    }

    /// Why the list might not be telling the whole truth, when it is not.
    ///
    /// Drawn above the people rather than in place of them: a refusal from the service means
    /// this list is the last thing it said and is still worth looking at, and the one thing
    /// worse than stale names is no names at all.
    ///
    /// The notice is drawn first, and before the failure and reconnect banners rather than after
    /// them, because one notice here is the app reporting something it already *did* about the
    /// connection: a server that moved, and an address this device followed it to. Those two
    /// facts are independent — a load that followed the move and then failed to authenticate says
    /// both, and hiding the first behind the second is how a person ends up being offered "set
    /// this device up again" for a device that had just done the right thing by itself.
    @ViewBuilder
    private var connection: some View {
        if let notice = session.notice {
            Section {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }

        if case .failed = session.phase {
            Section {
                Label {
                    VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                        Text("Not connected to your Crossbar")
                            .font(.subheadline.weight(.semibold))
                        Text(session.contacts.isEmpty
                             ? "Calls will not arrive until this clears. Check your connection, or try again."
                             : "The people below are the last ones it sent. Calls will not arrive until this clears.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Theme.symbol("wifi.exclamationmark", size: 22)
                        .foregroundStyle(.orange)
                }
                .accessibilityElement(children: .combine)

                Button("Try again") { Task { await session.load() } }

                // The way out for the case this screen is usually showing. An administrator who
                // switches the server between its two configurations leaves this device dialling
                // an address that belongs to the other one, and then nothing here can reach
                // anything. A server that names the new address — `origin` on `/api/health` —
                // is followed automatically and never reaches this screen; what is left here is
                // the switch this device could not follow, which is a server too old to name one
                // and a new address that does not answer yet. For those the app can offer the
                // only thing that fixes it, which is being set up again with the new details.
                // The confirmation says what it costs, because it costs the key.
                Button("Set this device up again") { confirmingSetUpAgain = true }
                    .accessibilityIdentifier("people.setUpAgain")
            }
        } else if case .retrying = session.phase {
            // A load that has not landed yet. Nothing is broken and no button is being asked
            // for, which is what separates this from the failure above it.
            reconnecting
        } else if session.eventsDown {
            // The stream is the only way a call can arrive, so this is not a detail: with it
            // down, the phone will not ring.
            reconnecting
        }
    }

    /// What the app says when it cannot reach the service and is still trying.
    ///
    /// One banner for both ways in — a load that has not landed yet, and a stream that has
    /// dropped — because from the person's side they are the same wait: nothing is broken, and
    /// nothing is being asked of them. The words are the app's own, and they were already here.
    private var reconnecting: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                    Text("Calls may not reach you")
                        .font(.subheadline.weight(.semibold))
                    Text("Reconnecting to your Crossbar. This clears on its own.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Theme.symbol("antenna.radiowaves.left.and.right.slash", size: 22)
                    .foregroundStyle(.orange)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.contacts.isEmpty {
            if case .failed = session.phase {
                ContentUnavailableView(
                    "No one to show yet",
                    systemImage: "wifi.exclamationmark",
                    description: Text("This app has not reached your Crossbar since it was last opened."))
            } else if case .loading = session.phase {
                // Nothing to say yet, and nothing worth saying: the people are on their way.
                ProgressView()
            } else if case .retrying = session.phase {
                // Past the moment for a spinner, and not a failure either: the app has not
                // reached the service yet, and says so in words rather than in an animation.
                ContentUnavailableView(
                    "No one to show yet",
                    systemImage: "wifi.exclamationmark",
                    description: Text("This app has not reached your Crossbar since it was last opened."))
            } else {
                ContentUnavailableView(
                    "No one is here yet",
                    systemImage: "person.2",
                    description: Text("People appear here once your Crossbar's administrator adds them. "
                        + "Ask them to add or invite someone."))
            }
        }
    }
}
