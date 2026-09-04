import SwiftUI
import TaxKit
import TaxPresentation

/// The app's visual vocabulary, in one place.
///
/// Relio was built correct before it was built to look at: default chrome, system greys,
/// and thirty-two reliefs in a flat list with nothing saying what any of them had to do
/// with any other. This is the layer that fixes that, and it is deliberately small — a
/// palette, a type scale and two shapes — because the interesting decision is the family
/// colour system and everything else should stay quiet around it.
enum Theme {

    // MARK: - Colour

    /// A family's hue, resolved for the current appearance.
    ///
    /// Built with a dynamic `UIColor` rather than an asset catalog because the build
    /// script that installs this app does not compile asset catalogs — the colours have to
    /// exist in code or they do not exist at all.
    static func tint(_ category: ReliefCategory) -> Color {
        let (light, dark) = category.tint
        return Color(uiColor: UIColor { trait in
            let c = trait.userInterfaceStyle == .dark ? dark : light
            // The taxonomy holds 0...255 integers because the package bans Double in its
            // own sources; the division belongs here, in the only target that needs the
            // fraction.
            return UIColor(red: CGFloat(c.red) / 255,
                           green: CGFloat(c.green) / 255,
                           blue: CGFloat(c.blue) / 255,
                           alpha: 1)
        })
    }

    /// The same hue at the weight a surface wants rather than a mark.
    static func wash(_ category: ReliefCategory) -> Color {
        tint(category).opacity(0.12)
    }

    /// A relief's family colour, falling back to the accent for a code no family claims.
    static func tint(for code: ReliefCode) -> Color {
        ReliefCategory(code).map(tint) ?? .accentColor
    }

    // MARK: - Type

    /// Money, and only money.
    ///
    /// `.rounded` is the one typographic risk here: SF's rounded numerals are warmer and
    /// more legible at a glance than the default, and a tax app that exists to say what
    /// you are owed should not set that figure in the same face as its form labels. Every
    /// other string stays on the system face, which is what keeps it a signature rather
    /// than a theme.
    static func figure(_ size: CGFloat, _ weight: Font.Weight = .bold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }

    /// Small, tracked, uppercase — for the eyebrow above a section.
    static let eyebrow = Font.system(size: 12, weight: .semibold).width(.expanded)

    // MARK: - Shape

    static let cardCorner: CGFloat = 16
    static let cardPadding: CGFloat = 16
}

/// A grouped surface. One shape, used everywhere something is a unit.
struct Card<Content: View>: View {
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .fill(.background.secondary)
            }
            .overlay(alignment: .leading) {
                // The family's colour as a spine down the leading edge rather than a
                // filled card: it identifies the group at a glance and leaves the content
                // on a neutral ground, where figures stay legible.
                if let tint {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(tint)
                        .frame(width: 4)
                        .padding(.vertical, 10)
                }
            }
    }
}

/// The family's name and colour, as a heading.
struct CategoryLabel: View {
    let category: ReliefCategory

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: category.symbol)
                .font(.caption2)
            Text(category.title)
                .font(Theme.eyebrow)
        }
        .foregroundStyle(Theme.tint(category))
        .accessibilityElement(children: .combine)
    }
}

/// A section heading that reads as one.
///
/// The Reliefs list has grouped by status since it was written — needs an answer, no one
/// to claim for, still claimable, granted, fully claimed — and the groups were invisible
/// because a default grouped-list header is small grey capitals that the eye skips. The
/// sections were doing real work and looked like nothing.
struct SectionHeading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .textCase(nil)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }
}
