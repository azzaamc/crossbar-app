import SwiftUI

/// Crossbar's design language, in one place.
///
/// Everything the interface is made of that is not a system control: the spacing between
/// things, the radii of the shapes that need one, the sizes of the few symbols large enough
/// to matter, and the parts that appear on more than one screen. It exists because the
/// screens had grown their own numbers — a 10 here, a 14 there, a 16 in a third place — and
/// nothing said whether a difference was deliberate or drift.
///
/// What is deliberately **not** here: colours. Crossbar uses the system's semantic colours
/// wherever it can, so light and dark mode, increased contrast and the accessibility settings
/// come for free and nothing has to be checked twice. The one exception is the accent, which
/// belongs to the asset catalogue, and which is the only colour in the app that is Crossbar's
/// own.
enum Theme {

    /// The spacing scale. Every gap in the app is one of these.
    enum Space {
        /// Between a symbol and the word beside it, inside one control.
        static let hairline: CGFloat = 4
        /// Between lines of the same thought.
        static let tight: CGFloat = 8
        /// Between the parts of one thing.
        static let snug: CGFloat = 12
        /// Between one thing and the next.
        static let normal: CGFloat = 16
        /// Between sections of a screen.
        static let loose: CGFloat = 28
        /// Around a screen's content, and around the block on an empty state.
        static let screen: CGFloat = 20
    }

    /// The shapes. Two radii, because there are two kinds of thing.
    enum Radius {
        /// Controls: buttons, fields, tiles that behave like one.
        static let control: CGFloat = 12
        /// Surfaces: the panel a call's controls sit on.
        static let surface: CGFloat = 22
    }

    /// How big a call control is, so a row of them can be laid out at whichever size fits.
    enum Control {
        static let regular: CGFloat = 64
        static let compact: CGFloat = 52
        /// The symbol inside a control of either size.
        static let symbol: CGFloat = 24
    }

    /// How big an avatar is, in each of the places one appears.
    enum Avatar {
        static let row: CGFloat = 44
        static let detail: CGFloat = 96
    }

    /// A symbol at the weight and scale Crossbar draws symbols at, everywhere.
    ///
    /// One weight, chosen once: mixing the default weight with an explicit size and an
    /// `.imageScale(.large)` in three different files is what makes an interface look
    /// assembled rather than designed, and it is invisible in any single screen.
    static func symbol(
        _ name: String,
        size: CGFloat,
        weight: Font.Weight = .medium,
        rendering: SymbolRenderingMode = .hierarchical
    ) -> some View {
        Image(systemName: name)
            .font(.system(size: size, weight: weight))
            .symbolRenderingMode(rendering)
    }
}

// MARK: - The parts more than one screen is made of

/// A person's initial on a tinted circle, at whichever size the place calls for.
///
/// Initials rather than a photograph, because this app has never had photographs and a
/// placeholder silhouette on every row says less than a letter does. The circle takes the
/// accent so that a list of people reads as one family of things.
struct Avatar: View {
    let initial: String
    var diameter: CGFloat = Theme.Avatar.row
    /// Whether to draw attention to it — a call in progress, an unread thing.
    var isProminent = false

    var body: some View {
        Circle()
            .fill(.tint.opacity(isProminent ? 0.28 : 0.15))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initial)
                    .font(.system(size: diameter * 0.42, weight: .semibold))
                    .foregroundStyle(.tint)
            }
            .accessibilityHidden(true)
    }
}

/// Whether somebody can be reached.
///
/// A dot is not enough on its own: it is the only place this app says "you can call them
/// now", and colour alone would leave it unsaid for anyone who cannot see it. So the dot is
/// drawn *and* the meaning is carried in the accessibility label of whatever row it is in —
/// see `PersonRow`.
struct PresenceDot: View {
    let isOnline: Bool
    var diameter: CGFloat = 11

    var body: some View {
        Circle()
            .fill(isOnline ? Color.green : Color.secondary.opacity(0.35))
            .frame(width: diameter, height: diameter)
            .overlay(Circle().stroke(.background, lineWidth: 2))
            .accessibilityHidden(true)
    }
}

/// Somebody you can call, as a row.
///
/// Takes what it needs and nothing more: a name, whether they are reachable, and what to do
/// when the row is tapped. It deliberately does not take the session, so that the layout of a
/// list of people can be seen — and changed — without a service to talk to.
struct PersonRow: View {
    let name: String
    let isOnline: Bool
    /// Called when the call button beside the row is tapped, never when the row is.
    let call: () -> Void

    private var initial: String {
        String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased()
    }

    var body: some View {
        HStack(spacing: Theme.Space.snug) {
            ZStack(alignment: .bottomTrailing) {
                Avatar(initial: initial, diameter: Theme.Avatar.row)
                PresenceDot(isOnline: isOnline)
            }

            Text(name)
                .font(.body.weight(.medium))
                .lineLimit(1)
                // The dot is the only place this app says "you can call them now", and a dot
                // is nothing to a screen reader. The meaning rides on the name instead, so
                // the row says it whether or not it can be seen.
                .accessibilityLabel("\(name), \(isOnline ? "available" : "not reachable")")

            Spacer(minLength: Theme.Space.tight)

            Button(action: call) {
                Theme.symbol("phone.fill", size: 18)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            // Borderless keeps only the button tappable: a whole row that places a call is a
            // call placed by accident, and this is the one action in the app that cannot be
            // taken back.
            .buttonStyle(.borderless)
            .accessibilityLabel("Call \(name)")
        }
    }
}

#Preview("People") {
    List {
        PersonRow(name: "Mum", isOnline: true) {}
        PersonRow(name: "Dad", isOnline: false) {}
        PersonRow(name: "Abdullah", isOnline: true) {}
    }
}
