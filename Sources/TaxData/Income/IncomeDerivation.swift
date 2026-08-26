import Foundation
import TaxKit

/// Turns an income timeline into one year's gross.
///
/// Pure: no SwiftData, no actor, no clock. The year is a parameter, exactly as it is for
/// `AgeCalculator`, so a figure derived today cannot change tomorrow — the same property
/// that makes the engine's golden files meaningful.
public enum IncomeDerivation {

    public static func annualGross(for year: Int, from sources: [IncomeSourceSnapshot]) -> Money {
        totals(for: year, from: sources).reduce(Money.zero) { $0 + $1.total }
    }

    /// The year's gross, or `nil` when nothing in the timeline reaches into that year.
    ///
    /// `annualGross` answers "how much", and its RM 0 for a year the timeline says nothing
    /// about is the honest answer to that question. This answers the prior question — "do
    /// we know at all?" — which is what the projection needs: handing the engine a
    /// confident RM 0.00 would claim the household earned nothing and produce a full set of
    /// tax figures for a year they have told us nothing about. Spec §6.
    ///
    /// A record that does reach into the year counts even when its amount is zero: a RM 0
    /// one-off dated inside it, or a RM 0 rate in force through it, is a real answer of
    /// nothing earned, not an absence of one.
    public static func knownAnnualGross(for year: Int,
                                        from sources: [IncomeSourceSnapshot]) -> Money? {
        let amounts = sources.flatMap { contributions(for: year, from: $0) }
        guard !amounts.isEmpty else { return nil }
        return amounts.reduce(Money.zero) { $0 + $1 }
    }

    /// Per-source subtotals, ordered by name then id so the screen is stable between
    /// launches and between devices.
    public static func totals(for year: Int,
                              from sources: [IncomeSourceSnapshot]) -> [IncomeSourceTotal] {
        sources
            .map { source in
                IncomeSourceTotal(sourceID: source.id, name: source.name,
                                  kind: source.kind, total: total(for: year, from: source))
            }
            .sorted { left, right in
                if left.name != right.name { return left.name < right.name }
                return left.sourceID.uuidString < right.sourceID.uuidString
            }
    }

    static func total(for year: Int, from source: IncomeSourceSnapshot) -> Money {
        contributions(for: year, from: source).reduce(Money.zero) { $0 + $1 }
    }

    /// Every amount this source contributes to `year`: one element per monthly slice of a
    /// recurring rate in force, and one per one-off dated inside the year.
    ///
    /// The single span walk, so "does this source say anything about the year" and "what
    /// does it say" can never disagree — the year is known exactly when this is non-empty,
    /// and its sum is the figure. A second copy of this logic could drift.
    private static func contributions(for year: Int,
                                      from source: IncomeSourceSnapshot) -> [Money] {
        let yearStart = IncomeCalendar.startOfYear(year)
        let yearEnd = IncomeCalendar.endOfYear(year)

        // A total order, so two devices cannot resolve the same records differently.
        let ordered = source.records.sorted { left, right in
            if left.effectiveFrom != right.effectiveFrom {
                return left.effectiveFrom < right.effectiveFrom
            }
            return left.id.uuidString < right.id.uuidString
        }

        let rates = ordered.filter { $0.shape == .recurring }
        var amounts: [Money] = []

        for (index, rate) in rates.enumerated() {
            // The next rate takes effect on its own date, so this one is paid through the
            // day before. `endedOn` is the last day the source paid, so it is inclusive.
            var spanEnd = yearEnd
            if index + 1 < rates.count {
                spanEnd = min(spanEnd, IncomeCalendar.dayBefore(rates[index + 1].effectiveFrom))
            }
            if let endedOn = source.endedOn {
                spanEnd = min(spanEnd, endedOn)
            }
            let spanStart = max(rate.effectiveFrom, yearStart)

            for span in IncomeCalendar.monthSpans(from: spanStart, through: spanEnd) {
                // A full month yields exactly the rate: days == daysInMonth makes the
                // factor 1 and `applying` returns the amount unchanged. Only partial
                // months round, and they round per month rather than once at the end.
                let factor = Decimal(span.days) / Decimal(span.daysInMonth)
                amounts.append(rate.amount.applying(factor, rounding: .halfUp))
            }
        }

        for oneOff in ordered where oneOff.shape == .oneOff {
            if IncomeCalendar.year(of: oneOff.effectiveFrom) == year {
                amounts.append(oneOff.amount)
            }
        }

        return amounts
    }
}
