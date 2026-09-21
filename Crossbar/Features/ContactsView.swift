import SwiftUI

/// Who you can call — the first screen, and the one that has to be right when somebody
/// is trying to reach their mother.
struct ContactsView: View {
    @ObservedObject var session: CallSession

    @State private var showSettings = false
    @State private var showIdentity = false

    var body: some View {
        NavigationStack {
            List {
                Section("On the network") {
                    ForEach(session.contacts) { contact in
                        ContactRow(session: session, contact: contact)
                    }
                }

                if session.eventsDown {
                    // The stream is the only way a call can arrive, so this is not a
                    // detail: with it down, the phone will not ring.
                    Section {
                        Label(
                            "Reconnecting to the service — calls may not reach you until this clears.",
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
                        .accessibilityIdentifier("network.route")
                }
            }
            .navigationTitle("Contacts")
            .refreshable { await session.refresh() }
            .overlay {
                if session.contacts.isEmpty {
                    ContentUnavailableView(
                        "No contacts yet",
                        systemImage: "person.2",
                        description: Text("People appear here once they are enrolled.")
                    )
                }
            }
            // The identity and the settings, in the corner they belong in. The instruments
            // moved to Settings → Advanced: still reachable, no longer the first thing a
            // thumb finds on the first screen.
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { settingsButton }
                ToolbarItem(placement: .topBarTrailing) { identityBubble }
            }
            .sheet(isPresented: $showSettings) { SettingsView(session: session) }
        }
    }

    private var initial: String {
        String(session.me?.displayName.prefix(1) ?? "?")
    }

    /// The identity, as a bubble rather than a row.
    ///
    /// It was a "Signed in as …" row at the head of the list, which read like a form field
    /// and said nothing about where the name came from. Tapping it says both, and the rest
    /// of the screen keeps its space for people.
    private var identityBubble: some View {
        Button {
            showIdentity.toggle()
        } label: {
            ZStack {
                Circle()
                    .fill(.tint.opacity(0.18))
                    .frame(width: 28, height: 28)
                Text(initial)
                    .font(.footnote.weight(.semibold))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("identity.bubble")
        .accessibilityLabel("Identity")
        .popover(isPresented: $showIdentity) {
            identityCard.presentationCompactAdaptation(.popover)
        }
    }

    private var identityCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(.tint.opacity(0.18))
                        .frame(width: 44, height: 44)
                    Text(initial)
                        .font(.title3.weight(.semibold))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.me?.displayName ?? "Not signed in")
                        .font(.headline)
                    if let relationship = session.me?.relationship, !relationship.isEmpty {
                        Text(relationship)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            Label("Identity comes from your tailnet sign-in", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("The service reads it from the network this device is on and injects it into "
                 + "every request. There is no account or password to change here.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Label("This device appears as \(TailnetNode.hostName)", systemImage: "iphone")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .frame(maxWidth: 320, alignment: .leading)
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
        }
        .accessibilityIdentifier("settings.open")
        .accessibilityLabel("Settings")
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
