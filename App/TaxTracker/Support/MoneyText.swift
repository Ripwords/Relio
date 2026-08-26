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
    }
}
