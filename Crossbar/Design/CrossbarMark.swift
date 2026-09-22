import SwiftUI

/// The mark the app is named after: a bar laid across another, with a ring at each place
/// they meet.
///
/// The artwork is the app icon's own, layer for layer — the same SVGs the icon is built from,
/// drawn here rather than redrawn, so the two cannot drift apart. They are copied into the
/// asset catalogue as template images, which is what lets the mark take the tint colour and
/// stay legible in the dark.
///
/// The icon's fourth layer is deliberately absent: it is the warm paper the icon sits on, and
/// this mark sits on the app's own background instead.
///
/// Each layer has to be made resizable. An SVG asset reports its canvas as its size — these are
/// drawn on a 1024-point one — so a stack of them overflows whatever frame it is given instead
/// of fitting it, and the mark is drawn several times larger than the screen.
struct CrossbarMark: View {
    var body: some View {
        ZStack {
            mark("CrossbarMarkHorizontal")
            mark("CrossbarMarkVertical")
            mark("CrossbarMarkNodes")
        }
        .aspectRatio(1, contentMode: .fit)
        .foregroundStyle(.tint)
        .accessibilityHidden(true)
    }

    private func mark(_ name: String) -> some View {
        Image(name)
            .resizable()
            .scaledToFit()
    }
}

#Preview {
    CrossbarMark()
        .frame(width: 120, height: 120)
        .padding()
}
