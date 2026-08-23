import Foundation

extension Money {

    /// The single display format for money in this app: `RM 2,500.00`.
    ///
    /// The `RM ` prefix is explicit rather than locale-derived, because the currency
    /// style's spacing and symbol placement drift between OS releases and would differ
    /// across iOS, macOS and watchOS. Only digit grouping is delegated to the locale.
    public func formatted() -> String {
        format(fractionDigits: 2)
    }

    /// `RM 2,500` — for progress rows where the sen are visual noise. Rounds half-up.
    public func formattedCompact() -> String {
        format(fractionDigits: 0)
    }

    private func format(fractionDigits: Int) -> String {
        let magnitude = Decimal(abs(sen)) / 100
        let digits = magnitude.formatted(
            .number
                .precision(.fractionLength(fractionDigits))
                .grouping(.automatic)
                .rounded(rule: .toNearestOrAwayFromZero)
                .locale(Locale(identifier: "en_MY"))
        )
        return sen < 0 ? "-RM \(digits)" : "RM \(digits)"
    }
}
