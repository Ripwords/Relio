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
        // The computed figure, spelled out. The expression above says the two sides agree;
        // this says what they agree *on*, so a change to `applying`'s rounding cannot move
        // both sides together and stay green. 8,000 x 1/31 = 258.06 and 9,500 x 30/31 =
        // 9,193.55, so January is 9,451.61, on top of eleven months at 9,500.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(sen: 11_395_161))
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
        // 9,000 x 1/28 = 321.43. Pinned as a literal so the rounding cannot drift with the
        // expression that computes it.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(sen: 932_143))
    }

    @Test("an end date between two rates clips the earlier rate and voids the later one")
    func endedOnBetweenTwoRates() {
        // Nothing exercised `spanEnd` being decided by the successor for one rate and by
        // `endedOn` for the next. Jan-Mar is clipped by the April raise; April onwards is
        // clipped by leaving on 15 August; and the two clips must compose.
        let job = Self.source(endedOn: Self.date(2025, 8, 15),
                              [Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 1))])
        // 3 x 8,000 = 24,000; 4 x 9,500 = 38,000; 1-15 August is 9,500 x 15/31 = 4,596.77.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [job]) == Money(sen: 6_659_677))

        // And when the end date falls before the successor takes effect at all, the later
        // rate contributes nothing rather than resuming after the source stopped paying.
        let quit = Self.source(endedOn: Self.date(2025, 4, 30),
                               [Self.rate(8_000, from: Self.date(2025, 1, 1)),
                                Self.rate(9_500, from: Self.date(2025, 9, 1))])
        #expect(IncomeDerivation.annualGross(for: 2025, from: [quit]) == Money(ringgit: 32_000))
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
        // Order-independence alone would also hold if both orders were equally wrong, so
        // pin which rate actually wins: the tie breaks on id, so `later` (BB) is second and
        // `earlier` (AA) is paid through the day before it — the same day — contributing
        // nothing. Jan-May at 8,000 is 40,000; June-December at 9,500 is 66,500.
        #expect(IncomeDerivation.annualGross(for: 2025, from: [one]) == Money(ringgit: 106_500))
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

    // MARK: - Known versus not known

    // `annualGross` answers "how much", and its RM 0 for a year the timeline says nothing
    // about is the honest answer to that question. `knownAnnualGross` answers the prior
    // question — "do we know at all?" — because the projection must not hand the engine a
    // confident RM 0.00 income for a year the household has told us nothing about.

    @Test("a source with no records at all is not known, rather than zero")
    func noRecordsIsUnknown() {
        // The moment between creating a source and saving its first rate.
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [Self.source([])]) == nil)
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: []) == nil)
    }

    @Test("a timeline that starts after the year is not known for that year")
    func earlierYearIsUnknown() {
        // Switching the year menu back to YA2024 with a 2025-only timeline must not claim
        // they earned nothing in 2024.
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.knownAnnualGross(for: 2024, from: [job]) == nil)
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [job]) == Money(ringgit: 96_000))
    }

    @Test("a source that ended in a past year is not known for a later one")
    func endedSourceIsUnknown() {
        let job = Self.source(endedOn: Self.date(2024, 6, 30),
                              [Self.rate(8_000, from: Self.date(2024, 1, 1))])
        #expect(IncomeDerivation.knownAnnualGross(for: 2024, from: [job]) == Money(ringgit: 48_000))
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [job]) == nil)
    }

    @Test("a zero amount inside the year is a real answer, not an absence")
    func zeroInsideTheYearIsKnown() {
        // A RM 0 one-off dated in the year, and a RM 0 rate in force through it, both say
        // something about the year: nothing was earned. That is an answer, and it is not
        // the same as never having been asked.
        let bonus = Self.source([Self.oneOff(0, on: Self.date(2025, 5, 1))])
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [bonus]) == Money.zero)

        let unpaid = Self.source([Self.rate(0, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [unpaid]) == Money.zero)
    }

    @Test("when the year is known, the figure is the same one annualGross derives")
    func knownFigureMatchesAnnualGross() {
        // The two must never disagree: the same walk decides both whether a record
        // contributes and what it contributes.
        let job = Self.source("Main job", [Self.rate(8_000, from: Self.date(2024, 4, 1)),
                                           Self.rate(9_000, from: Self.date(2025, 7, 1)),
                                           Self.oneOff(12_000, on: Self.date(2025, 2, 14))])
        let flat = Self.source("Rental", kind: .rental,
                               [Self.rate(1_500, from: Self.date(2025, 1, 1))])
        for year in [2024, 2025] {
            #expect(IncomeDerivation.knownAnnualGross(for: year, from: [job, flat])
                    == IncomeDerivation.annualGross(for: year, from: [job, flat]))
        }
    }

    @Test("one source reaching into the year makes the year known for all of them")
    func oneContributingSourceIsEnough() {
        // The empty source contributes nothing to the sum, but the year is still known
        // because the other one reaches into it.
        let job = Self.source("Main job", [Self.rate(8_000, from: Self.date(2025, 1, 1))])
        #expect(IncomeDerivation.knownAnnualGross(for: 2025, from: [Self.source("New job", []), job])
                == Money(ringgit: 96_000))
    }

    @Test("a mid-month raise leaves two April slices that group back into one April wage")
    func midMonthRaiseGroupsBackIntoOneMonth() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15))])
        let slices = IncomeDerivation.monthlyContributions(for: 2025, from: job)

        let april = slices.filter { $0.month == WageMonth(year: 2025, month: 4) }
        #expect(april.count == 2)
        #expect(april.map(\.amount) == [Money(ringgit: 3_733.33), Money(ringgit: 5_066.67)])
        // The point of the label. Summing the already-rounded slices of one month is what
        // a statutory wage is assessed on, and it is exactly 8,800 — not 8,799.99 or
        // 8,800.01, which is what rounding once at the end would produce.
        #expect(april.reduce(Money.zero) { $0 + $1.amount } == Money(ringgit: 8_800))

        #expect(slices.reduce(Money.zero) { $0 + $1.amount } == Money(ringgit: 108_800))
    }

    @Test("every month of the year is labelled, in calendar order")
    func everyMonthIsLabelled() {
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1))])
        let slices = IncomeDerivation.monthlyContributions(for: 2025, from: job)
        #expect(slices.map(\.month) == (1...12).map { WageMonth(year: 2025, month: $0) })
        #expect(slices.allSatisfy { $0.origin == .recurringRate })
    }

    @Test("a one-off is labelled with the month it was received, and named as one")
    func oneOffCarriesItsOriginAndMonth() {
        // A consumer assessing a statutory wage has to be able to leave one-offs out: a
        // bonus is EPF wages but not SOCSO wages, and Relio cannot tell one from a
        // travel allowance, which is neither.
        let job = Self.source([Self.rate(8_000, from: Self.date(2025, 1, 1)),
                               Self.oneOff(12_000, on: Self.date(2025, 11, 20))])
        let slices = IncomeDerivation.monthlyContributions(for: 2025, from: job)

        let oneOffs = slices.filter { $0.origin == .oneOff }
        #expect(oneOffs.count == 1)
        #expect(oneOffs.first?.month == WageMonth(year: 2025, month: 11))
        #expect(oneOffs.first?.amount == Money(ringgit: 12_000))
        // November carries both, and they stay separable.
        #expect(slices.filter { $0.month == WageMonth(year: 2025, month: 11) }.count == 2)
    }

    @Test("the labelled slices are the same walk the gross is derived from")
    func oneWalkBehindBoth() {
        // The property the single walk exists for: "does this source say anything about
        // the year" and "what does it say" cannot disagree, and now neither can "which
        // months did it say it about". A second walk beside this one could drift.
        let job = Self.source("Main job", endedOn: Self.date(2025, 8, 20),
                              [Self.rate(8_000, from: Self.date(2024, 4, 15)),
                               Self.rate(9_500, from: Self.date(2025, 4, 15)),
                               Self.oneOff(2_000, on: Self.date(2025, 2, 3))])
        let quiet = Self.source("New job", [])

        for source in [job, quiet] {
            for year in [2023, 2024, 2025, 2026] {
                let slices = IncomeDerivation.monthlyContributions(for: year, from: source)
                #expect(slices.reduce(Money.zero) { $0 + $1.amount }
                        == IncomeDerivation.total(for: year, from: source))
                #expect(slices.isEmpty
                        == (IncomeDerivation.knownAnnualGross(for: year, from: [source]) == nil))
            }
        }
    }

    @Test("the derivation path contains no Double")
    func noDoubleInDerivation() throws {
        // This is a calculation path feeding chargeable income. `Double` here would
        // reintroduce exactly the representation error `Money` exists to prevent, at the
        // point where a user's salary becomes a tax figure.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let income = root.appending(path: "Sources/TaxData/Income")
        let files = try FileManager.default
            .contentsOfDirectory(at: income, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                guard text.contains("Double") else { continue }
                // Checking the whole line lets a real `Double` through as long as the line
                // also has a `//` anywhere on it — `let x: Double = 0 // temp` contains both
                // substrings. Only the code before the first `//` can be a genuine `Double`;
                // an occurrence after the marker is inside the comment itself and must still
                // pass, so the check is scoped to the code segment, not the raw line.
                let code = text.split(separator: "//", maxSplits: 1, omittingEmptySubsequences: false)[0]
                #expect(!code.contains("Double"),
                        "\(file.lastPathComponent):\(number + 1) uses Double on the derivation path")
            }
        }
    }
}
