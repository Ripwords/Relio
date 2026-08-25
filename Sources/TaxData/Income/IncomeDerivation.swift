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
        var running = Money.zero

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
                running = running + rate.amount.applying(factor, rounding: .halfUp)
            }
        }

        for oneOff in ordered where oneOff.shape == .oneOff {
            if IncomeCalendar.year(of: oneOff.effectiveFrom) == year {
                running = running + oneOff.amount
            }
        }

        return running
    }
}
