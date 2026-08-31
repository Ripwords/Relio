import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Statutory contribution floors") struct StatutoryContributionFloorTests {

    static func born(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    static func month(_ year: Int, _ month: Int) -> WageMonth {
        WageMonth(year: year, month: month)
    }

    static func floor(_ scheme: ContributionScheme,
                      _ profile: ContributorProfile,
                      _ month: WageMonth,
                      wage sen: Int) -> Money {
        StatutoryContributionFloors.floorRule(scheme: scheme, profile: profile, month: month)
            .table.employeeFloor(forMonthlyWage: Money(sen: sen))
    }

    static let citizen = NationalityClass.malaysianCitizen
    static let everyMonth = (2022...2026).flatMap { year in
        (1...12).map { WageMonth(year: year, month: $0) }
    }

    // MARK: - What the schedules actually print

    /// The least the social security schedules can print for a band.
    ///
    /// SOCSO Category 1 pays 0.5% of the band's assumed wage and EIS 0.2%, each printed to
    /// five sen — and they round in opposite directions in the low bands, so this bounds
    /// them from below rather than reproducing them. Working in tenths of a sen keeps the
    /// arithmetic exact and integral.
    static func leastPublished(assumedWageSen: Int) -> Int {
        let downToFiveSen = { (tenths: Int) in tenths / 50 * 50 }
        return (downToFiveSen(assumedWageSen / 20) + downToFiveSen(assumedWageSen / 50)) / 10
    }

    /// The EPF Third Schedule's printed employee amount for a wage, in sen.
    ///
    /// `ceil(rate × band upper limit)`, rounded up to the ringgit — the rule that
    /// reproduces all 401 printed rows of every Part with no mismatch. The opening band
    /// pays nothing at all.
    static func publishedEPF(rateNumerator: Int, wageSen: Int) -> Int {
        guard wageSen > 1_000 else { return 0 }
        let upperSen: Int
        switch wageSen {
        case ...2_000:      upperSen = 2_000
        case ...500_000:    upperSen = (wageSen + 1_999) / 2_000 * 2_000
        case ...2_000_000:  upperSen = (wageSen + 9_999) / 10_000 * 10_000
        default:            upperSen = wageSen
        }
        let hundredthsOfARinggit = rateNumerator * upperSen
        return (hundredthsOfARinggit + 9_999) / 10_000 * 100
    }

    /// Every band's upper limit in ringgit, written out rather than generated.
    ///
    /// Transcribed from Act 800's Second Schedule and Act 4's Fourth Schedule. Rebuilding
    /// the list with the shipped table's own widths expression would let a slip in that
    /// expression pass by agreeing with itself, which is the one thing this oracle exists
    /// not to do.
    static let printedBandUpperLimits = [
        30, 50, 70, 100, 140, 200, 300, 400, 500, 600, 700, 800, 900, 1_000, 1_100, 1_200,
        1_300, 1_400, 1_500, 1_600, 1_700, 1_800, 1_900, 2_000, 2_100, 2_200, 2_300, 2_400,
        2_500, 2_600, 2_700, 2_800, 2_900, 3_000, 3_100, 3_200, 3_300, 3_400, 3_500, 3_600,
        3_700, 3_800, 3_900, 4_000, 4_100, 4_200, 4_300, 4_400, 4_500, 4_600, 4_700, 4_800,
        4_900, 5_000, 5_100, 5_200, 5_300, 5_400, 5_500, 5_600, 5_700, 5_800, 5_900, 6_000,
    ]

    /// Every social security band up to a ceiling, lowest first, in sen.
    ///
    /// The band's assumed wage is its midpoint, except the first, which the Fourth
    /// Schedule fixes at RM20 rather than at the RM15 a midpoint would give.
    static func bands(ceilingRinggit: Int) -> [(lower: Int, upper: Int, assumed: Int)] {
        let uppers = printedBandUpperLimits.prefix { $0 <= ceilingRinggit }
        let lowers = [0] + uppers.dropLast()
        return zip(lowers, uppers).enumerated().map { index, band in
            (band.0 * 100, band.1 * 100, index == 0 ? 2_000 : (band.0 + band.1) * 50)
        }
    }

    @Test("the shipped ladder has a rung at each printed band and nowhere else")
    func ladderMatchesThePrintedBands() {
        for (era, ceiling) in zip(StatutoryContributionFloors.socialSecurityLadders,
                                  [5_000, 6_000]) {
            guard case let .stepLadder(steps) = era.basis else {
                Issue.record("era \(ceiling) is not a step ladder"); continue
            }
            #expect(steps.map(\.monthlyWageAtLeast.sen)
                    == Self.bands(ceilingRinggit: ceiling).map { $0.lower + 1 })
        }
    }

    // MARK: - The floor never exceeds the truth

    @Test("the EPF floor never exceeds the Third Schedule, at any wage")
    func epfFloorIsALowerBound() {
        // Sweeping the wage rather than the band, because the failure this guards against
        // is a lookup landing one band too high, not an arithmetic slip inside a band.
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        for wageSen in stride(from: 0, through: 2_500_000, by: 977) {
            let proven = Self.floor(.employeesProvidentFund, profile,
                                    Self.month(2024, 6), wage: wageSen)
            #expect(proven.sen <= Self.publishedEPF(rateNumerator: 11, wageSen: wageSen),
                    "EPF floor \(proven.sen) exceeds the schedule at wage \(wageSen) sen")
        }
    }

    @Test("the opening NIL band is honoured, where a bare percentage would overshoot")
    func epfNilBand() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        // The schedule pays nothing at all up to RM10, so 11% of RM10 — a sen — would be
        // a claim above the truth.
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 6), wage: 1_000) == .zero)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 6), wage: 1_001) == Money(sen: 110))
    }

    @Test("the social security floor never exceeds either schedule, at any wage")
    func socialSecurityFloorIsALowerBound() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        for (month, ceiling) in [(Self.month(2024, 6), 5_000), (Self.month(2024, 10), 6_000)] {
            for band in Self.bands(ceilingRinggit: ceiling) {
                let least = Self.leastPublished(assumedWageSen: band.assumed)
                // Both ends of the band and a point inside it: a rung keyed one sen off
                // shows up at an end, a wrong amount shows up anywhere.
                for wageSen in [band.lower + 1, (band.lower + band.upper) / 2, band.upper] {
                    let proven = Self.floor(.socialSecurity, profile, month, wage: wageSen)
                    #expect(proven.sen <= least,
                            "social security floor \(proven.sen) exceeds the least the schedules can print (\(least)) at wage \(wageSen) sen")
                }
            }
        }
    }

    @Test("the RM600 wage that a bare 0.7% would overstate")
    func theAssumedWageTrap() {
        // RM600 sits in the band that runs from RM500, whose assumed wage is RM550, so the
        // schedules pay RM2.75 + RM1.10 = RM3.85. A flat 0.7% of the actual RM600 would be
        // RM4.20 — above the truth, and the guarantee gone.
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        let proven = Self.floor(.socialSecurity, profile, Self.month(2024, 6), wage: 60_000)
        #expect(proven <= Money(sen: 385))
        #expect(proven > Money(sen: 300))
    }

    @Test("the ladder never falls as the wage rises")
    func ladderIsMonotonic() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        var previous = Money.zero
        for wageSen in stride(from: 0, through: 700_000, by: 137) {
            let proven = Self.floor(.socialSecurity, profile, Self.month(2024, 10), wage: wageSen)
            #expect(previous <= proven, "the ladder fell at wage \(wageSen) sen")
            previous = proven
        }
    }

    @Test("the published maxima are exact at each insured-wage ceiling")
    func publishedMaxima() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        // RM24.75 SOCSO Category 1 plus RM9.90 EIS at the RM5,000 ceiling; RM29.75 plus
        // RM11.90 at RM6,000. At the ceiling the insured wage stops rising, so the printed
        // amount is the answer for every higher wage and the floor is the truth exactly.
        for wageSen in [500_000, 900_000, 5_000_000] {
            #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 9), wage: wageSen)
                    == Money(sen: 3_465))
        }
        for wageSen in [600_000, 900_000, 5_000_000] {
            #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 10), wage: wageSen)
                    == Money(sen: 4_165))
        }
        // Raising the ceiling moves the exact rung up with it. A RM5,000 wage was at the
        // ceiling under the old era and is an ordinary band under the new one, where the
        // floor is the rate on that band's lower limit and sits under the printed RM34.65.
        #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 10), wage: 500_000)
                == Money(sen: 3_430))
    }

    @Test("the insured-wage ceiling rises on the October 2024 wage month, not before")
    func ceilingChangesOnTheRightWageMonth() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        let wellPaid = 800_000
        #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 8), wage: wellPaid)
                == Money(sen: 3_465))
        #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 9), wage: wellPaid)
                == Money(sen: 3_465))
        #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 10), wage: wellPaid)
                == Money(sen: 4_165))
        #expect(Self.floor(.socialSecurity, profile, Self.month(2024, 11), wage: wellPaid)
                == Money(sen: 4_165))
        // The ceiling is keyed to the wage month, which is why these tables cannot live in
        // a rulebook keyed to a Year of Assessment: it moved inside YA2024.
        #expect(Self.floor(.socialSecurity, profile, Self.month(2025, 3), wage: wellPaid)
                == Money(sen: 4_165))
    }

    // MARK: - Who the contributor is

    @Test("a Malaysian citizen aged 60 or over has no EPF floor at all")
    func citizenAtSixtyContributesNothing() {
        // Third Schedule Part E: the employee's share is 0%. Assuming 11% here fabricates
        // the whole RM4,000 relief and understates tax by roughly RM960, which is the
        // largest single error the naive derivation makes.
        let profile = ContributorProfile(dateOfBirth: Self.born(1964, 3, 20),
                                         nationality: Self.citizen)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 2), wage: 500_000) == Money(sen: 55_000))
        for month in [Self.month(2024, 3), Self.month(2024, 12), Self.month(2025, 6)] {
            #expect(Self.floor(.employeesProvidentFund, profile, month, wage: 500_000) == .zero)
        }
    }

    @Test("the age switch takes the birthday month itself, the smaller of the two readings")
    func ageSwitchTakesTheEarlierReading() {
        // Which month the switch takes effect is unresolved. Every rate on the far side of
        // the threshold is at or below the rate on the near side, so taking the birthday
        // month itself yields the smaller floor whichever reading turns out to be right.
        let profile = ContributorProfile(dateOfBirth: Self.born(1964, 3, 31),
                                         nationality: Self.citizen)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 3), wage: 500_000) == .zero)
    }

    @Test("a permanent resident aged 60 or over pays half the rate, not none and not all")
    func permanentResidentAtSixty() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1964, 3, 20),
                                         nationality: .permanentResident)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 2), wage: 500_000) == Money(sen: 55_000))
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2024, 3), wage: 500_000) == Money(sen: 27_500))
    }

    @Test("a non-Malaysian proves nothing before October 2025 and 2% after")
    func nonMalaysianEPF() {
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15), nationality: .other)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2025, 9), wage: 500_000) == .zero)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2025, 10), wage: 500_000) == Money(sen: 10_000))
    }

    @Test("a non-Malaysian's EPF floor does not need a date of birth")
    func nonMalaysianNeedsNoAge() {
        // The rate is the same on both sides of 60, so the unanswered question cannot
        // change the answer and is not raised. That falls out of the arithmetic; there is
        // no branch anywhere that reads `dateOfBirth == nil`.
        let rule = StatutoryContributionFloors.floorRule(
            scheme: .employeesProvidentFund,
            profile: ContributorProfile(nationality: .other),
            month: Self.month(2025, 10))
        #expect(rule.missing.isEmpty)
        #expect(rule.table.employeeFloor(forMonthlyWage: Money(sen: 500_000)) == Money(sen: 10_000))
    }

    @Test("the 9% opt-out window is not derivable, so wages before July 2022 prove nothing")
    func pandemicRateWindow() {
        // The employee rate was 9% on January 2021 through June 2022 wages and opting back
        // up to 11% took a form. Relio cannot know who filed one, so 11% is not a floor.
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                         nationality: Self.citizen)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2022, 6), wage: 500_000) == .zero)
        #expect(Self.floor(.employeesProvidentFund, profile,
                           Self.month(2022, 7), wage: 500_000) == Money(sen: 55_000))
    }

    @Test("social security proves nothing from the month the taxpayer turns 55")
    func socialSecurityStopsAtFiftyFive() {
        // Category 2 pays no employee share at all, and it covers anyone who first
        // contributed at 55 or over. Relio cannot know when someone first contributed, so
        // from 55 the admissible contributors include one who pays nothing.
        let profile = ContributorProfile(dateOfBirth: Self.born(1969, 5, 10),
                                         nationality: Self.citizen)
        #expect(Self.floor(.socialSecurity, profile,
                           Self.month(2024, 4), wage: 800_000) == Money(sen: 3_465))
        #expect(Self.floor(.socialSecurity, profile,
                           Self.month(2024, 5), wage: 800_000) == .zero)
    }

    @Test("social security proves nothing for a non-Malaysian")
    func socialSecurityForANonMalaysian() {
        // Whether EIS covers a non-citizen employee is not settled here, and the combined
        // ladder would overstate if it does not. An unsettled question resolves toward the
        // smaller figure.
        let profile = ContributorProfile(dateOfBirth: Self.born(1990, 6, 15), nationality: .other)
        #expect(Self.floor(.socialSecurity, profile,
                           Self.month(2024, 10), wage: 800_000) == .zero)
    }

    // MARK: - What Relio refuses to prove, and why

    @Test("an unanswered question always means the table proves nothing")
    func missingImpliesProvesNothing() {
        // The invariant the whole refusal rests on, over every combination of the two
        // facts, both schemes and five years of wage months.
        let dates: [Date?] = [nil, Self.born(1990, 6, 15), Self.born(1964, 3, 20),
                              Self.born(1969, 5, 10)]
        let nationalities: [NationalityClass?] = [nil] + NationalityClass.allCases

        for scheme in ContributionScheme.allCases {
            for date in dates {
                for nationality in nationalities {
                    let profile = ContributorProfile(dateOfBirth: date, nationality: nationality)
                    for month in Self.everyMonth {
                        let rule = StatutoryContributionFloors.floorRule(
                            scheme: scheme, profile: profile, month: month)
                        guard !rule.missing.isEmpty else { continue }
                        #expect(rule.table == .provesNothing)
                        #expect(rule.table.employeeFloor(forMonthlyWage: Money(sen: 800_000))
                                == .zero)
                    }
                }
            }
        }
    }

    @Test("a question is only raised when its answer is one Relio does not have")
    func onlyUnansweredFactsAreAsked() {
        let month = Self.month(2024, 6)
        for scheme in ContributionScheme.allCases {
            #expect(StatutoryContributionFloors.floorRule(
                scheme: scheme, profile: ContributorProfile(), month: month).missing
                    == [.nationality, .dateOfBirth])

            #expect(StatutoryContributionFloors.floorRule(
                scheme: scheme,
                profile: ContributorProfile(dateOfBirth: Self.born(1990, 6, 15)),
                month: month).missing == [.nationality])

            #expect(StatutoryContributionFloors.floorRule(
                scheme: scheme,
                profile: ContributorProfile(nationality: Self.citizen),
                month: month).missing == [.dateOfBirth])

            #expect(StatutoryContributionFloors.floorRule(
                scheme: scheme,
                profile: ContributorProfile(dateOfBirth: Self.born(1990, 6, 15),
                                            nationality: Self.citizen),
                month: month).missing.isEmpty)
        }
    }

    @Test("a settled zero is not a question")
    func settledRefusalsAskNothing() {
        // A Malaysian citizen aged 60 or over proves nothing under EPF, and no further
        // answer would change that, so nothing is asked.
        let rule = StatutoryContributionFloors.floorRule(
            scheme: .employeesProvidentFund,
            profile: ContributorProfile(dateOfBirth: Self.born(1964, 3, 20),
                                        nationality: Self.citizen),
            month: Self.month(2024, 6))
        #expect(rule.table == .provesNothing)
        #expect(rule.missing.isEmpty)
    }

    @Test("every table that states a figure cites where the figure comes from")
    func everyShippedFigureIsSourced() {
        let profiles = [
            ContributorProfile(dateOfBirth: Self.born(1990, 6, 15), nationality: Self.citizen),
            ContributorProfile(dateOfBirth: Self.born(1964, 3, 20), nationality: .permanentResident),
            ContributorProfile(dateOfBirth: Self.born(1990, 6, 15), nationality: .other),
        ]
        var sourced = 0
        for scheme in ContributionScheme.allCases {
            for profile in profiles {
                for month in Self.everyMonth {
                    let table = StatutoryContributionFloors.floorRule(
                        scheme: scheme, profile: profile, month: month).table
                    guard table.basis != .nothing else { continue }
                    #expect(table.sourceURL != nil)
                    sourced += 1
                }
            }
        }
        #expect(sourced > 0)
    }

    // MARK: - Which wage months a Year of Assessment can draw on

    @Test("the two basis-year readings differ by one month at each boundary")
    func basisYearReadings() {
        // Para 46(1)(n) relieves a contribution "made or suffered in that basis year";
        // Act 812's 2019 redraft dropped the equivalent clause for EPF. A January wage is
        // remitted in February, so the readings shift by a month. Neither is hard-coded.
        #expect(StatutoryContributionFloors.wageMonths(inYear: 2024, reading: .wagesInYear)
                == (1...12).map { Self.month(2024, $0) })
        #expect(StatutoryContributionFloors.wageMonths(inYear: 2024, reading: .remittedInYear)
                == [Self.month(2023, 12)] + (1...11).map { Self.month(2024, $0) })
    }

    @Test("both readings cover twelve wage months")
    func readingsAreTwelveMonthsEach() {
        for reading in StatutoryContributionFloors.BasisYearReading.allCases {
            #expect(StatutoryContributionFloors.wageMonths(inYear: 2025, reading: reading).count == 12)
        }
    }
}
