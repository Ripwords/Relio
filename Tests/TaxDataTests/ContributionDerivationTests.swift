import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Contribution derivation") struct ContributionDerivationTests {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    static func rate(_ ringgit: Decimal, from date: Date) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(shape: .recurring, amount: Money(ringgit: ringgit),
                             effectiveFrom: date)
    }

    static func oneOff(_ ringgit: Decimal, on date: Date) -> IncomeRecordSnapshot {
        IncomeRecordSnapshot(shape: .oneOff, amount: Money(ringgit: ringgit),
                             effectiveFrom: date)
    }

    static func source(_ name: String,
                       id: UUID = UUID(),
                       epf: Bool? = nil,
                       socso: Bool? = nil,
                       endedOn: Date? = nil,
                       _ records: [IncomeRecordSnapshot]) -> IncomeSourceSnapshot {
        IncomeSourceSnapshot(id: id, name: name, kind: .employment,
                             deductsEPF: epf, deductsSOCSO: socso,
                             endedOn: endedOn, records: records)
    }

    static let citizenUnderSixty = ContributorProfile(dateOfBirth: date(1990, 6, 15),
                                                      nationality: .malaysianCitizen)
    static let epfCap = Money(ringgit: 4_000)
    static let socsoCap = Money(ringgit: 350)

    // Sources come first, because Swift cannot skip a defaulted parameter to reach a
    // later positional one — the same reason `IncomeDerivationTests` carries two `source`
    // overloads.
    static func estimate(_ sources: [IncomeSourceSnapshot],
                         scheme: ContributionScheme = .employeesProvidentFund,
                         year: Int = 2024,
                         profile: ContributorProfile = citizenUnderSixty) -> ContributionEstimate {
        ContributionDerivation.estimate(scheme: scheme, year: year,
                                        from: sources, profile: profile)
    }

    // MARK: - When the timeline says nothing

    @Test("a silent timeline proves nothing and asks nothing")
    func noWageRecords() {
        let found = Self.estimate([])
        // `nil` rather than RM 0.00, the same distinction `knownAnnualGross` draws: RM 0
        // is a claim that nothing was contributed, and silence is not that claim.
        #expect(found.annualFloor == nil)
        #expect(found.basis.isEmpty)
        #expect(found.missing.isEmpty)
        #expect(found.certainty(against: Self.epfCap) == .noWageRecords)
    }

    @Test("a bonus on its own is not a wage record")
    func oneOffsAloneProveNothing() {
        // A one-off could be a bonus, overtime or a travel allowance, and Relio cannot
        // tell them apart. There is no wage month here to assess, so there is no point
        // asking anyone's date of birth either.
        let found = Self.estimate([Self.source("Acme", epf: true,
                                               [Self.oneOff(50_000, on: Self.date(2024, 6, 30))])])
        #expect(found.annualFloor == nil)
        #expect(found.certainty(against: Self.epfCap) == .noWageRecords)
    }

    @Test("a source that stopped paying before the year raises no question about it")
    func questionsFollowTheWageMonths() {
        // There is no point asking whether a job deducted EPF in a year it did not pay.
        let found = Self.estimate([
            Self.source("Old job", epf: nil, endedOn: Self.date(2020, 12, 31),
                        [Self.rate(5_000, from: Self.date(2019, 1, 1))]),
            Self.source("Acme", epf: true, [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
        ])
        #expect(found.missing.isEmpty)
        #expect(found.annualFloor == Money(ringgit: 2_904))
        #expect(found.basis.map(\.name) == ["Acme"])
    }

    // MARK: - The dominant case

    @Test("a full year above the cap is the cap exactly, not an estimate of it")
    func dominantPersonaReachesTheCap() {
        // Whatever the statement says, the contribution is at least the floor, and every
        // figure at or above the floor clamps to the same cap. That is a proof.
        let found = Self.estimate([Self.source("Acme", epf: true,
                                               [Self.rate(8_800, from: Self.date(2023, 1, 1))])])
        #expect(found.annualFloor == Money(ringgit: 11_616))
        #expect(found.certainty(against: Self.epfCap) == .exactlyTheCap(Self.epfCap))
        #expect(found.missing.isEmpty)
    }

    @Test("a full year below the cap is offered as a bound, not as the figure")
    func belowTheCap() {
        let found = Self.estimate([Self.source("Acme", epf: true,
                                               [Self.rate(2_200, from: Self.date(2023, 1, 1))])])
        #expect(found.annualFloor == Money(ringgit: 2_904))
        #expect(found.certainty(against: Self.epfCap) == .atLeast(Money(ringgit: 2_904)))
    }

    @Test("the year a Malaysian citizen turns 60 accounts only for the months before it")
    func turnsSixtyInMarch() {
        // The RM960 error, refused out loud in the one year it is genuinely partial.
        let found = Self.estimate(
            [Self.source("Acme", epf: true, [Self.rate(3_200, from: Self.date(2023, 1, 1))])],
            profile: ContributorProfile(dateOfBirth: Self.date(1964, 3, 20),
                                        nationality: .malaysianCitizen))
        #expect(found.annualFloor == Money(ringgit: 704))
        #expect(found.basis.first?.months
                == WageMonth(year: 2024, month: 1)...WageMonth(year: 2024, month: 2))
    }

    // MARK: - Two readings of the basis year

    @Test("the floor is the smaller of the two basis-year readings")
    func basisYearMinimum() {
        // Employment that starts on 1 January 2024 has twelve wage months in the year and
        // eleven remitted during it, and the readings disagree. Relio keeps the smaller,
        // which is a floor whichever reading is right.
        let fromJanuary = Self.estimate([Self.source("Acme", epf: true,
                                                     [Self.rate(2_200, from: Self.date(2024, 1, 1))])])
        #expect(fromJanuary.annualFloor == Money(ringgit: 2_662))

        // A salary already running the December before makes the readings agree, so the
        // steady case pays nothing for the caution.
        let fromTheYearBefore = Self.estimate([Self.source("Acme", epf: true,
                                                           [Self.rate(2_200, from: Self.date(2023, 1, 1))])])
        #expect(fromTheYearBefore.annualFloor == Money(ringgit: 2_904))
    }

    // MARK: - Per employment, never aggregated

    @Test("two employments are floored separately and then summed")
    func perEmploymentThenSummed() {
        // Aggregating the wages first errs in both directions. Two RM3,000 salaries sit in
        // the band that runs from RM2,900, RM20.30 each; one RM6,000 salary would sit at
        // the insured-wage ceiling at RM41.65. The per-employment figure is the smaller
        // and the correct one.
        let found = Self.estimate([
            Self.source("Acme", socso: true, [Self.rate(3_000, from: Self.date(2024, 1, 1))]),
            Self.source("Beta", socso: true, [Self.rate(3_000, from: Self.date(2024, 1, 1))]),
        ], scheme: .socialSecurity, year: 2025)
        #expect(found.annualFloor == Money(sen: 48_720))
        #expect(found.basis.map(\.floor) == [Money(sen: 24_360), Money(sen: 24_360)])
    }

    @Test("a social security floor below the cap stays below it")
    func socialSecurityBelowTheCap() {
        let found = Self.estimate([
            Self.source("Acme", socso: true, [Self.rate(1_500, from: Self.date(2024, 1, 1))]),
        ], scheme: .socialSecurity, year: 2025)
        #expect(found.annualFloor == Money(sen: 11_760))
        #expect(found.certainty(against: Self.socsoCap) == .atLeast(Money(sen: 11_760)))
    }

    // MARK: - The three-valued flag

    @Test("an unasked source raises a question; a source confirmed no does not")
    func unaskedAndConfirmedNo() {
        let unasked = UUID()
        let found = Self.estimate([
            Self.source("Acme", id: unasked, epf: nil,
                        [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
            Self.source("Beta", epf: false, [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
        ])
        // Different meanings for the user, identical arithmetic: neither contributes.
        #expect(found.annualFloor == .zero)
        #expect(found.missing == [.sourceDeducts(scheme: .employeesProvidentFund,
                                                 sourceID: unasked)])
        #expect(found.certainty(against: Self.epfCap)
                == .blocked(missing: [.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: unasked)]))
    }

    @Test("a source confirmed to deduct nothing is a floor of zero, not a question")
    func confirmedNoIsSettled() {
        let found = Self.estimate([Self.source("Acme", epf: false,
                                               [Self.rate(2_200, from: Self.date(2023, 1, 1))])])
        #expect(found.annualFloor == .zero)
        #expect(found.missing.isEmpty)
        #expect(found.certainty(against: Self.epfCap) == .atLeast(.zero))
    }

    // MARK: - What is still unknown

    @Test("an unknown contributor blocks, and names both facts")
    func unknownProfileBlocks() {
        let found = Self.estimate([Self.source("Acme", epf: true,
                                               [Self.rate(8_800, from: Self.date(2023, 1, 1))])],
                                  profile: ContributorProfile())
        #expect(found.annualFloor == .zero)
        #expect(found.missing == [.nationality, .dateOfBirth])
        #expect(found.certainty(against: Self.epfCap)
                == .blocked(missing: [.nationality, .dateOfBirth]))
    }

    @Test("an unasked source is worth the profile questions too")
    func unaskedSourceCarriesTheProfileQuestions() {
        // Answering "does Acme deduct EPF?" on its own would prove nothing, because the
        // rate still depends on facts nobody has been asked for. The card offers the whole
        // set, in one stable order.
        let acme = UUID()
        let found = Self.estimate([Self.source("Acme", id: acme, epf: nil,
                                               [Self.rate(8_800, from: Self.date(2023, 1, 1))])],
                                  profile: ContributorProfile())
        #expect(found.missing == [.nationality, .dateOfBirth,
                                  .sourceDeducts(scheme: .employeesProvidentFund,
                                                 sourceID: acme)])
    }

    @Test("a floor that already reaches the cap is not blocked by an open question")
    func capBeatsTheOutstandingQuestions() {
        // No answer can raise a relief that is already at its limit, so there is nothing
        // worth asking for.
        let found = Self.estimate([
            Self.source("Acme", epf: true, [Self.rate(8_800, from: Self.date(2023, 1, 1))]),
            Self.source("Beta", epf: nil, [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
        ])
        #expect(!found.missing.isEmpty)
        #expect(found.certainty(against: Self.epfCap) == .exactlyTheCap(Self.epfCap))
    }

    // MARK: - What the screen needs to say why

    @Test("a one-off never enters the wage base")
    func oneOffsAreDropped() {
        let withBonus = Self.estimate([
            Self.source("Acme", epf: true, [Self.rate(2_200, from: Self.date(2023, 1, 1)),
                                            Self.oneOff(10_000, on: Self.date(2024, 6, 30))]),
        ])
        let without = Self.estimate([
            Self.source("Acme", epf: true, [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
        ])
        #expect(withBonus.annualFloor == without.annualFloor)
    }

    @Test("the basis names each source, its months and its own floor")
    func basisPerSource() {
        let found = Self.estimate([
            Self.source("Zed", epf: true, [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
            Self.source("Acme", epf: true, [Self.rate(1_100, from: Self.date(2023, 1, 1))]),
        ])
        #expect(found.basis.map(\.name) == ["Acme", "Zed"])
        #expect(found.basis.map(\.floor) == [Money(ringgit: 1_452), Money(ringgit: 2_904)])
        #expect(found.annualFloor == Money(ringgit: 4_356))
        for entry in found.basis {
            #expect(entry.months == WageMonth(year: 2024, month: 1)...WageMonth(year: 2024, month: 12))
        }
    }

    @Test("every shipped figure carries the source it came from")
    func sourceURLsAreReported() {
        let found = Self.estimate([Self.source("Acme", epf: true,
                                               [Self.rate(8_800, from: Self.date(2023, 1, 1))])])
        #expect(found.sourceURLs.count == 1)
        #expect(found.sourceURLs.first?.host() == "www.kwsp.gov.my")

        // Nothing proven, nothing to cite.
        #expect(Self.estimate([Self.source("Acme", epf: true,
                                          [Self.rate(8_800, from: Self.date(2023, 1, 1))])],
                              profile: ContributorProfile()).sourceURLs.isEmpty)
    }

    @Test("a raise month's rounding never carries the wage into the band above")
    func raiseMonthTiesStayInTheBand() {
        // Both halves of this June land on an exact half-sen tie, and half-up rounding
        // carries the summed month a sen over the RM3,000 the source really paid — enough
        // to read the rung above. The exact wage sits in the band that runs from RM2,900,
        // where the schedules print RM14.75 plus RM5.90; the rung above would claim
        // RM21.00, above the truth and the guarantee gone.
        let found = Self.estimate([
            Self.source("Acme", socso: true, endedOn: Self.date(2024, 6, 30), [
                IncomeRecordSnapshot(shape: .recurring, amount: Money(sen: 299_999),
                                     effectiveFrom: Self.date(2024, 6, 1)),
                IncomeRecordSnapshot(shape: .recurring, amount: Money(sen: 300_001),
                                     effectiveFrom: Self.date(2024, 6, 16)),
            ]),
        ], scheme: .socialSecurity)
        #expect(found.annualFloor == Money(sen: 2_030))
        #expect(found.annualFloor! <= Money(sen: 2_065))
    }

    @Test("a part-month wage is still a floor")
    func partialMonths() {
        // The derivation pro-rates a month a source only paid part of, and a pro-rated
        // wage is below the contractual one — so its band is at or below the real band and
        // its floor is still a floor. No special case, and nothing to get wrong.
        let found = Self.estimate([
            Self.source("Acme", epf: true, endedOn: Self.date(2024, 6, 15),
                        [Self.rate(2_200, from: Self.date(2023, 1, 1))]),
        ])
        #expect(found.annualFloor != nil)
        #expect(found.annualFloor! < Money(ringgit: 2_904))
        #expect(found.basis.first?.months
                == WageMonth(year: 2024, month: 1)...WageMonth(year: 2024, month: 6))
    }
}
