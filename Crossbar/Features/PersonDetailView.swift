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
struct PersonDetailView: View {
    @ObservedObject var session: CallSession
    let contact: FamilyContact

    private var initial: String {
        String(contact.displayName.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        List {
            Section {
                VStack(spacing: Theme.Space.snug) {
                    Avatar(initial: initial, diameter: Theme.Avatar.detail, isProminent: contact.online)
                    Text(contact.displayName)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)
                    Label(contact.online ? "Available" : "Not reachable now",
                          systemImage: contact.online ? "checkmark.circle.fill" : "moon.zzz.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.normal)
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            Section {
                Button {
                    session.placeCall(to: contact, video: false)
                } label: {
                    Label("Call \(contact.displayName)", systemImage: "phone.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.borderedProminent)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("person.call")

                Button {
                    session.placeCall(to: contact, video: true)
                } label: {
                    Label("Video call \(contact.displayName)", systemImage: "video.fill")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                }
                .buttonStyle(.bordered)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("person.videoCall")
            } footer: {
                // The dot and this sentence both say whether they are reachable *now*, which
                // is not the same as whether they will pick up. The copy stops where the
                // presence record does.
                Text(contact.online
                     ? "\(contact.displayName) is on the network. Whether they pick up is up to them."
                     : "They are not on the network at the moment. A call will arrive when they open Crossbar.")
            }

            Section {
                LabeledContent("Reachable", value: contact.online ? "Now" : "Not at the moment")
                if let ago = Reading.ago(contact.lastSeen) {
                    LabeledContent("Last seen", value: ago)
                }
            } header: {
                Text("Availability")
            }
        }
        .navigationTitle(contact.displayName)
        .navigationBarTitleDisplayMode(.inline)
    }
}
