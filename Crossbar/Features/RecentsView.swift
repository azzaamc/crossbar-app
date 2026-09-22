import SwiftUI

/// What has happened, newest first.
///
/// Deliberately the shape of the Phone app's Recents: who, when, what became of it, and a way
/// to ring back from the row. Nothing here reports *why* a call did not connect — that is a
/// diagnostics question, it has a screen of its own under Settings, and a person looking at
/// their missed calls is not asking it.
struct RecentsView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        List {
            ForEach(session.history) { call in
                RecentRow(call: call, session: session)
            }
        }
        .navigationTitle("Recents")
        .refreshable { await session.refresh() }
        .overlay { emptyState }
    }

    @ViewBuilder
    private var emptyState: some View {
        if session.history.isEmpty {
            ContentUnavailableView(
                "No calls yet",
                systemImage: "clock",
                description: Text("Calls you make and calls that arrive appear here."))
        }
    }
}

/// One finished call, as a row.
private struct RecentRow: View {
    let call: RecentCall
    @ObservedObject var session: CallSession

    /// Which way it went. The service reports who placed it; whether that was this person is a
    /// fact the app already has, and it does not need the service to repeat it.
    private var isOutgoing: Bool { call.callerId == session.me?.id }

    /// Whether anybody ever joined.
    ///
    /// Read from the record rather than from a word the server chose: a call somebody was on
    /// was answered, and a call nobody joined was not, whatever the participation row is
    /// spelled as. That way the row cannot disagree with the record it came from.
    private var wasAnswered: Bool { call.joinedAt != nil }

    private var isMissed: Bool { !isOutgoing && !wasAnswered }

    private var symbol: String {
        if isMissed { return "phone.arrow.down.left" }
        return isOutgoing ? "phone.arrow.up.right" : "phone.arrow.down.left"
    }

    /// Everyone else on it, when there was more than the person who placed it.
    private var title: String {
        if let others = call.others, !others.isEmpty { return others }
        return call.callerName ?? "Unknown"
    }

    private var detail: String {
        if isOutgoing { return "Outgoing" }
        return wasAnswered ? "Incoming" : "Missed"
    }

    /// The person to ring back: whoever placed the call.
    private var callBack: FamilyContact? {
        session.contacts.first { $0.id == call.callerId }
    }

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            Theme.symbol(symbol, size: 19)
                .foregroundStyle(isMissed ? Color.red : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                Text(title)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                    .accessibilityLabel("\(title), \(detail), \(Reading.when(call.startedAt))")

                HStack(spacing: Theme.Space.hairline) {
                    Text(detail)
                    if let length = Reading.duration(from: call.joinedAt, to: call.leftAt) {
                        Text("·")
                        Text(length)
                    }
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            }

            Spacer(minLength: Theme.Space.tight)

            Text(Reading.when(call.startedAt))
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let contact = callBack {
                Button {
                    session.placeCall(to: contact)
                } label: {
                    Theme.symbol("phone.fill", size: 17)
                        .frame(width: 40, height: 40)
                        .contentShape(Circle())
                }
                // Borderless keeps only the button tappable, as everywhere else a row has a
                // call action: a whole row that rings somebody is a call placed by accident.
                .buttonStyle(.borderless)
                .accessibilityLabel("Call \(contact.displayName) back")
            }
        }
    }
}
