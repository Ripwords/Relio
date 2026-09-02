import SwiftUI
import TaxKit

/// The only place a `Money` becomes a `View`.
///
/// Global constraint: one formatter, and interpolating an amount into user-facing text
/// anywhere else is a defect. Routing every amount through one view makes that a
/// one-line grep, and gives `.monospacedDigit()` a single home — spec §11.2 requires
/// figures not jitter while a value animates.
struct MoneyText: View {
    let amount: Money
    var font: Font = .body
    var weight: Font.Weight = .regular

    var body: some View {
        Text(amount.formatted())
            .font(font.weight(weight))
            .monospacedDigit()
            // Never split a figure across lines. "RM 3,50" above "0.00" is not a wrapped
            // label, it is two numbers that are not the amount — and it is what a bare
            // HStack does at the largest Dynamic Type sizes. One line also makes the
            // amount report an honest width, which is what lets `AdaptiveRow`'s
            // `ViewThatFits` know the row does not fit and stack instead.
            .lineLimit(1)
            // Shrink rather than truncate. `lineLimit(1)` alone turns "RM 3,500.00" into
            // "RM 3,500.…" when the row is narrow, which is the same defect as splitting
            // it — the reader is shown something that is not the amount. A figure that is
            // slightly smaller is still the figure.
            .minimumScaleFactor(0.6)
    }
}
