import SwiftUI

/// What is new, and the only writing in this app that is not derived from something.
///
/// Shown once per release: on the first launch after an update, and on a fresh install, where
/// there is no earlier version to compare against and everything is new. The record is the
/// version string, so however many times the app is opened afterwards the screen does not come
/// back — see `AppSettings.lastSeenVersion`.
struct ReleaseNotes: Identifiable {
    var id: String { version }

    /// The release these belong to, spelled as `CFBundleShortVersionString` spells it.
    let version: String

    /// One line saying what the release is, above the list.
    let headline: String

    let changes: [Change]

    /// One thing that changed.
    struct Change: Identifiable {
        /// Which kind of change it was, which is also the word it is filed under.
        enum Kind: String {
            case added = "Added"
            case improved = "Improved"
            case fixed = "Fixed"
            case note = "Note"

            var symbol: String {
                switch self {
                case .added: return "plus.circle.fill"
                case .improved: return "arrow.up.circle.fill"
                case .fixed: return "wrench.adjustable.fill"
                case .note: return "info.circle.fill"
                }
            }
        }

        var id: String { "\(kind.rawValue): \(text)" }
        let kind: Kind
        /// One sentence, in the second person, about what this app does now that it did not.
        let text: String
    }
}

extension ReleaseNotes {
    /// Every release this build knows about, newest first.
    ///
    /// Written by hand, and it is the one thing in this app that has to be: what changed is a
    /// judgement about what a person would notice, and there is nothing in the code to read it
    /// off. A release with no entry here shows nothing and is still recorded as read, so a build
    /// with no notes cannot surface the notes for the release before it.
    static let all: [ReleaseNotes] = [
        ReleaseNotes(
            version: "1.0",
            headline: "Crossbar's first release.",
            changes: [
                Change(kind: .added,
                       text: "Call the people on your Crossbar — one to one, or with up to four on the call."),
                Change(kind: .added,
                       text: "Video calls, and audio calls that stay audio until you turn the camera on."),
                Change(kind: .added,
                       text: "A call rings your phone even when Crossbar is closed on it, and one you miss "
                           + "leaves a notification."),
                Change(kind: .added,
                       text: "Recents shows every call you made and took, with a way to ring back from the row."),
                Change(kind: .improved,
                       text: "The People list says when somebody was last on Crossbar."),
                Change(kind: .improved,
                       text: "An audio call has a screen of its own rather than a video frame with nothing in it."),
            ]
        ),
    ]

    /// The version this copy of the app reports.
    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    /// The notes for the release running now, once.
    ///
    /// Records the version as it answers, so a second call for the same release returns nothing:
    /// this is for the launch after an update, not for every launch.
    static func takeForCurrentBuild() -> ReleaseNotes? {
        let running = currentVersion
        guard AppSettings.lastSeenVersion != running else { return nil }
        AppSettings.lastSeenVersion = running
        return all.first { $0.version == running }
    }
}

/// What changed, once.
///
/// A sheet rather than a screen of its own, because it is not somewhere anybody goes: it is
/// something the app has to say, and it says it and gets out of the way.
struct ReleaseNotesView: View {
    let notes: ReleaseNotes

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(notes.headline)
                        .font(.headline)
                }

                Section {
                    ForEach(notes.changes) { change in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.snug) {
                            Theme.symbol(change.kind.symbol, size: 18)
                                .foregroundStyle(.tint)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: Theme.Space.hairline) {
                                Text(change.kind.rawValue)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(change.text)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                } header: {
                    Text("Version \(notes.version)")
                }
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue") { dismiss() }
                        .accessibilityIdentifier("releaseNotes.continue")
                }
            }
        }
    }
}

// A preview is safe here, and only here, because this view takes plain data and touches nothing:
// no session, no network, no call. See the note at the bottom of `ContentView` for what happens
// when a preview is put on a view that owns one.
#Preview("Release notes") {
    ReleaseNotesView(notes: ReleaseNotes.all[0])
}
