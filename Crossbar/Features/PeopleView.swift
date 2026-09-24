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
    private func presence(of contact: FamilyContact) -> String {
        if contact.online { return "On Crossbar now" }
        if let ago = Reading.ago(contact.lastSeen) { return "Last seen \(ago)" }
        return "Not on Crossbar now"
    }

    /// Why the list might not be telling the whole truth, when it is not.
    ///
    /// Drawn above the people rather than in place of them: a refusal from the service means
    /// this list is the last thing it said and is still worth looking at, and the one thing
    /// worse than stale names is no names at all.
    @ViewBuilder
    private var connection: some View {
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
            }
        } else if session.eventsDown {
            // The stream is the only way a call can arrive, so this is not a detail: with it
            // down, the phone will not ring.
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
        } else if let notice = session.notice {
            Section {
                Text(notice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
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
