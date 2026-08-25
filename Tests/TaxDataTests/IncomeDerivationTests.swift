import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Income derivation") struct IncomeDerivationTests {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    static func rate(_ ringgit: Decimal, from date: Date, id: UUID = UUID()) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(id: id, shape: .recurring,
                             amount: Money(ringgit: ringgit), effectiveFrom: date)
    }

    static func oneOff(_ ringgit: Decimal, on date: Date, id: UUID = UUID()) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(id: id, shape: .oneOff,
                             amount: Money(ringgit: ringgit), effectiveFrom: date)
    }

    // Two overloads rather than a single defaulted `name`: Swift cannot skip a
    // positional (unlabeled) parameter to reach a later positional one, so a lone
    // `Self.source([...])` call needs the name-less overload below.
    static func source(kind: IncomeKind = .employment,
                       endedOn: Date? = nil,
                       _ records: [IncomeRecordSnapshot]) -> IncomeSourceSnapshot {
        IncomeSourceSnapshot(id: UUID(), name: "Main job", kind: kind,
                             endedOn: endedOn, records: records)
    }

    static func source(_ name: String,
                       kind: IncomeKind = .employment,
                       endedOn: Date? = nil,
                       _ records: [IncomeRecordSnapshot]) -> IncomeSourceSnapshot {
        IncomeSourceSnapshot(id: UUID(), name: name, kind: kind,
                             endedOn: endedOn, records: records)
    }

    @Test("a flat salary for a whole year is twelve times the rate, with no rounding")
    func flatYear() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 96_000))
    }

    @Test("one rate spanning a year boundary is counted correctly in both years")
    func rateCarriesForward() {
        // The whole reason sources are global rather than per-year: a salary set in April
        // 2024 is still in force in January 2025 and must not need re-entering.
        let job = Self.source([Self.rate(8_000, from: Self.date(2024, 4, 1))])
        // 2024 gets April through December — nine months, not twelve.
        #expect(IncomeDerivation.annualGross(for: 2024, from: [job]) == Money(ringgit: 72_000))
        // 2025 gets all twelve, from a record that names no 2025 date at all.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 96_000))
        // And the year before it existed gets nothing.
        #expect(IncomeDerivation.annualGross(for: 2023, from: [job]) == Money.zero)
    }

    @Test("a raise on the first of a month has no partial month at all")
    func raiseOnTheFirst() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 1))])
        // Jan–Mar at 8,000, Apr–Dec at 9,500. No pro-rating anywhere.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 3 * 8_000 + 9 * 9_500))
    }

    @Test("a mid-month raise blends the month by days")
    func raiseMidMonth() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        // April, computed by hand: 1–14 on the old rate is 8,000 × 14/30 = 3,733.33 (rounds
        // DOWN); 15–30 on the new rate is 9,500 × 16/30 = 5,066.67 (rounds UP). They sum to
        // exactly 8,800.00. An implementation that rounds once at the end, or truncates,
        // gets a different number and would pass a whole-months-only test.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 24_000) + Money(sen: 880_000) + Money(ringgit: 76_000))
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 108_800))
    }

    @Test("the old rate is paid through the day before the new one starts")
    func handoverIsExclusive() {
        // One day at 8,000 then the rest of January at 9,500. If the boundary were
        // inclusive on both sides, 2 January would be paid twice.
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 1, 2))])
        let january = Money(ringgit: 8_000).applying(Decimal(1) / Decimal(31))
            + Money(ringgit: 9_500).applying(Decimal(30) / Decimal(31))
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == january + Money(ringgit: 11 * 9_500))
    }

    @Test("a job that ends is paid through its last day, inclusive")
    func endedOnIsInclusive() {
        let job = Self.source(endedOn: Self.date(2025, 8, 31),
                              [Self.rate(9_000, from: Self.date(2025, 1, 1))])
        // Eight whole months. Ending on the 31st means that day counted.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(ringgit: 72_000))
    }

    @Test("a job that ends on the first counts one day, not zero")
    func endedOnFirstCountsOneDay() {
        let job = Self.source(endedOn: Self.date(2025, 2, 1),
                              [Self.rate(9_000, from: Self.date(2025, 1, 1))])
        let expected = Money(ringgit: 9_000)                                  // all January
            + Money(ringgit: 9_000).applying(Decimal(1) / Decimal(28))        // 1 February
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == expected)
    }

    @Test("one-off amounts count only in the year they were received")
    func oneOffsAreDated() {
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14)),
            Self.oneOff(2_400, on: Self.date(2025, 7, 2)),
            Self.oneOff(950, on: Self.date(2025, 11, 9)),
            Self.oneOff(5_000, on: Self.date(2024, 12, 31))     // last year's, excluded
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [side]) == Money(ringgit: 5_150))
        #expect(IncomeDerivation.annualGross(for: 2024, from: [side]) == Money(ringgit: 5_000))
    }

    @Test("a one-off counts even when no rate is in force")
    func oneOffIndependentOfRates() {
        // A bonus paid after leaving a job is still income received that year.
        let job = Self.source(endedOn: Self.date(2025, 6, 30), [
            Self.rate(9_000, from: Self.date(2025, 1, 1)),
            Self.oneOff(4_000, on: Self.date(2025, 9, 1))
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job])
                == Money(ringgit: 54_000) + Money(ringgit: 4_000))
    }

    @Test("the worked example from the spec")
    func workedExample() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14)),
            Self.oneOff(2_400, on: Self.date(2025, 7, 2)),
            Self.oneOff(950, on: Self.date(2025, 11, 9))
        ])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job, side])
                == Money(ringgit: 113_950))
    }

    @Test("totals are per source, in a stable order, and sum to the gross")
    func totalsPerSource() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        let side = Self.source("Design freelance", kind: .occasional, [
            Self.oneOff(1_800, on: Self.date(2025, 3, 14))
        ])
        let totals = IncomeDerivation.totals(for: 2025, from: [job, side])
        #expect(totals.count == 2)
        #expect(totals.map(\.name) == ["Design freelance", "Main job"])   // by name, then id
        #expect(totals.reduce(Money.zero) { $0 + $1.total }
                == IncomeDerivation.annualGross(for: 2025, from: [job, side]))
    }

    @Test("business and rental income is counted, not quietly dropped")
    func outOfScopeKindsStillCount() {
        // Spec §8: excluding them would understate chargeable income, which overstates what
        // every relief is worth — the harmful direction. The warning is how the caveat is
        // delivered; the arithmetic includes them.
        let shop = Self.source("Side business", kind: .business,
                               [Self.oneOff(12_000, on: Self.date(2025, 5, 1))])
        let flat = Self.source("Rental", kind: .rental,
                               [Self.rate(1_500, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [shop, flat])
                == Money(ringgit: 12_000) + Money(ringgit: 18_000))
    }

    @Test("records out of order and tied on date resolve deterministically")
    func orderingIsTotal() {
        let earlier = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let later = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let day = Self.date(2025, 6, 1)
        // Two rates on the same day, supplied in both orders. Whatever the rule picks, it
        // must pick the same one every time or two devices disagree about income.
        let one = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_000, from: day, id: earlier),
                               Self.rate(9_500, from: day, id: later)])
        let two = Self.source([Self.rate(9_500, from: day, id: later),
                               Self.rate(9_000, from: day, id: earlier),
                               Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [one])
                == IncomeDerivation.annualGross(for: 2025, from: [two]))
    }

    @Test("no income at all is zero, not a crash")
    func emptyIsZero() {
        #expect(IncomeDerivation.annualGross(for: 2025, from: []) == Money.zero)
        #expect(IncomeDerivation.annualGross(for: 2025, from: [Self.source([])]) == Money.zero)
    }

    @Test("a rate starting after the year ends contributes nothing")
    func futureRateIsIgnored() {
        let job = Self.source([Self.rate(9_000, from: Self.date(2026, 3, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money.zero)
    }
}
