import SwiftUI

/// One person, and the one thing you can do with them.
///
/// A screen rather than a row's worth of buttons, because calling is the only action this app
/// has on a person and it is the one it cannot take back. The row calls directly, which is
/// what somebody in a hurry wants; this is where they go when they want to see who they are
/// about to ring.
///
/// Nothing here exposes a device id, a key or an address. Those are real, they belong to the
/// service rather than to this person, and they are under Settings where someone debugging
/// would look for them.
///
/// **Nothing here says whether this person can be reached**, and that is a correction rather
/// than an omission. This screen used to carry a dot and two sentences about reachability,
/// written when a call needed the far end's app to be open. It does not any more: a call rings
/// their phone through a push, on the lock screen, with Crossbar closed. So there is no state
/// of theirs in which calling them fails to arrive, and a screen saying "not reachable now"
/// was describing a limitation this app no longer has — the worst kind of wrong copy, because
/// it would talk somebody out of a call that would have worked.
///
/// What presence still says is that they are *at their phone*, which is worth knowing for a
/// different reason: it is the difference between a call that gets picked up and one that does
/// not. That is what the line under their name is for.
struct PersonDetailView: View {
    @ObservedObject var session: CallSession
    let contact: FamilyContact

    private var initial: String { Avatar.initial(of: contact.displayName) }

    /// The one thing this app knows about where they are, and nothing about whether a call
    /// would reach them — it always reaches them. See the type's own note.
    private var presence: String {
        if contact.online { return "On Crossbar now" }
        if let ago = Reading.ago(contact.lastSeen) { return "Last seen \(ago)" }
        return "Not on Crossbar now"
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Theme.Space.snug) {
                    Avatar(initial: initial, diameter: Theme.Avatar.detail, isProminent: contact.online)
                    Text(contact.displayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Text(presence)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.normal)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            // The two buttons share one row, and that is two fixes in one line of structure.
            // A `List` draws a separator *between* rows, which is the faint line that was
            // cutting across these two; and two rows each carrying its own insets is how they
            // came to be a different width from each other and from everything above them.
            // One row, one inset, one stack — and `.controlSize(.large)` for the height, which
            // is the same control size the onboarding buttons use rather than a hand-set 32.
            Section {
                VStack(spacing: Theme.Space.snug) {
                    Button {
                        session.placeCall(to: contact, video: false)
                    } label: {
                        Label("Call \(contact.displayName)", systemImage: "phone.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .accessibilityIdentifier("person.call")

                    Button {
                        session.placeCall(to: contact, video: true)
                    } label: {
                        Label("Video call \(contact.displayName)", systemImage: "video.fill")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .accessibilityIdentifier("person.videoCall")
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            } footer: {
                // What is actually true of a call now, which is what the old copy got wrong:
                // it is delivered to their phone whatever state Crossbar is in. Whether they
                // answer is the only part left that is up to them.
                Text("A call rings their phone even when Crossbar is closed on it. Whether they pick up is up to them.")
            }
        }
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
