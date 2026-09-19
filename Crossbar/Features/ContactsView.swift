import SwiftUI

/// Who you can call — the first screen, and the one that has to be right when somebody
/// is trying to reach their mother.
struct ContactsView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        NavigationStack {
            List {
                if let me = session.me {
                    Section {
                        LabeledContent("Signed in as", value: me.displayName)
                    }
                }

                Section("Family") {
                    ForEach(session.contacts) { contact in
                        ContactRow(session: session, contact: contact)
                    }
                }

                if session.eventsDown {
                    // The stream is the only way a call can arrive, so this is not a
                    // detail: with it down, the phone will not ring.
                    Section {
                        Label(
                            "Reconnecting to Family Call — calls may not reach you until this clears.",
                            systemImage: "wifi.exclamationmark"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                }

                if let notice = session.notice {
                    Section {
                        Text(notice)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section {
                    // Which route is carrying this app belongs on the screen, not only in a
                    // log: carrying its own tailnet is the entire point of the embedded node,
                    // and the Tailscale app is still installed on this phone, so a working
                    // connection does not by itself say which one it came through.
                    Label(session.tailnetRoute, systemImage: "lock.shield")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("family.route")
                }
            }
            .navigationTitle("Family Call")
            .refreshable { await session.load() }
            .overlay {
                if session.contacts.isEmpty {
                    ContentUnavailableView(
                        "No contacts yet",
                        systemImage: "person.2",
                        description: Text("Family members appear here once they are enrolled.")
                    )
                }
            }
            #if DEBUG
            // The instruments live behind this rather than owning the app: they are how
            // the wire contract gets re-measured, and they must not be the product.
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Probe") { ProbeView() }
                }
            }
            #endif
        }
    }
}

private struct ContactRow: View {
    @ObservedObject var session: CallSession
    let contact: FamilyContact

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .bottomTrailing) {
                Circle()
                    .fill(.tint.opacity(0.15))
                    .frame(width: 42, height: 42)
                    .overlay {
                        Text(String(contact.displayName.prefix(1)))
                            .font(.headline)
                    }

                // Reachable right now. It says nothing about whether they will answer,
                // and a grey dot is not an error.
                Circle()
                    .fill(contact.online ? .green : .secondary.opacity(0.4))
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.background, lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(contact.displayName)
                    .font(.body.weight(.medium))
                if let relationship = contact.relationship, !relationship.isEmpty {
                    Text(relationship)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                session.placeCall(to: contact)
            } label: {
                Image(systemName: "phone.fill")
                    .padding(.horizontal, 6)
            }
            // Borderless keeps only the button tappable; otherwise the whole row places
            // a call, which is not a thing to do by accident.
            .buttonStyle(.borderless)
            .accessibilityLabel("Call \(contact.displayName)")
        }
    }
}
