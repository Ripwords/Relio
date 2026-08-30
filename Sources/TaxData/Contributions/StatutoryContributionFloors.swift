import Foundation
import TaxKit

/// The statutory floor tables, and the rule that picks one.
///
/// Payroll facts keyed to a **wage month**, which is why they are here and not in the
/// rulebook: the social security insured-wage ceiling moved on 1 September 2022 and again
/// on 1 October 2024, mid-Year-of-Assessment both times, and a YA-keyed JSON rulebook
/// cannot express a fact that changes inside the year it keys on. They are Swift constants
/// rather than a bundled resource because a decode failure on a money path is worse than a
/// recompile.
public enum StatutoryContributionFloors {

    /// The table that applies to a wage month, and the questions that had to go unanswered
    /// to get there.
    ///
    /// One call returning both. Two functions — one for the table, one for the questions —
    /// could drift into disagreeing about whether Relio knows enough to derive, which is
    /// the failure `IncomeDerivation`'s single span walk exists to avoid.
    ///
    /// The refusal is arithmetic rather than a special case, and that is the point. Each
    /// unanswered fact widens the set of contributors the records admit, so the rule reads
    /// every admissible contributor's table and keeps one only when they all agree. With
    /// no nationality the admissible set includes a Malaysian citizen aged 60 or over,
    /// whose rate is 0%, so the set cannot agree and nothing is proven. There is no branch
    /// anywhere that reads `dateOfBirth == nil`, and nothing to forget to write.
    ///
    /// It follows that a fact whose answer could not change the table is never asked
    /// about: a non-Malaysian's EPF rate is the same on both sides of 60, so the
    /// admissible tables agree and the date of birth goes unrequested. And a settled zero
    /// asks nothing either, because the admissible tables agree on proving nothing.
    ///
    /// Invariant, asserted by `StatutoryContributionFloorTests`: `missing` non-empty
    /// implies the table is `.provesNothing`.
    public static func floorRule(scheme: ContributionScheme,
                                 profile: ContributorProfile,
                                 month: WageMonth)
        -> (table: ContributionFloorTable, missing: [ContributionQuestion]) {

        let nationalities = profile.nationality.map { [$0] } ?? NationalityClass.allCases
        let standings = profile.dateOfBirth
            .map { [standing(bornOn: $0, reaching: scheme.ageThreshold, in: month)] }
            ?? AgeStanding.allCases

        let admissible = nationalities.flatMap { nationality in
            standings.map { standing in
                table(scheme: scheme, nationality: nationality, standing: standing, month: month)
            }
        }

        guard let settled = admissible.first,
              admissible.allSatisfy({ $0 == settled }) else {
            var missing: [ContributionQuestion] = []
            if profile.nationality == nil { missing.append(.nationality) }
            if profile.dateOfBirth == nil { missing.append(.dateOfBirth) }
            return (.provesNothing, missing)
        }
        return (settled, [])
    }

    /// Which side of a scheme's age threshold a wage month falls on.
    enum AgeStanding: Hashable, Sendable, CaseIterable {
        case below
        case atOrAbove
    }

    /// The month the taxpayer reaches an age, taken as the birthday month itself.
    ///
    /// Which month the switch takes effect is unresolved: no KWSP or PERKESO statement
    /// settles whether it is the birthday month or the one after. Every rate on the far
    /// side of both thresholds is at or below the rate on the near side — EPF falls from
    /// 11% to nothing or to 5.5%, social security to nothing — so the earlier of the two
    /// candidate months yields the smaller floor under either reading, and the bound holds
    /// whichever turns out to be right. A 29 February birth reaches the threshold in
    /// February for the same reason.
    private static func standing(bornOn birthDate: Date, reaching age: Int,
                                 in month: WageMonth) -> AgeStanding {
        let born = WageMonth(containing: birthDate)
        let reached = WageMonth(year: born.year + age, month: born.month)
        return month < reached ? .below : .atOrAbove
    }

    private static func table(scheme: ContributionScheme,
                              nationality: NationalityClass,
                              standing: AgeStanding,
                              month: WageMonth) -> ContributionFloorTable {
        let candidate: ContributionFloorTable
        switch (scheme, nationality, standing) {

        case (.employeesProvidentFund, .malaysianCitizen, .below),
             (.employeesProvidentFund, .permanentResident, .below):
            candidate = epfUnderSixty

        case (.employeesProvidentFund, .permanentResident, .atOrAbove):
            candidate = epfPermanentResidentAtSixty

        case (.employeesProvidentFund, .malaysianCitizen, .atOrAbove):
            // Third Schedule Part E: the employee's share is 0%. Assuming 11% here
            // fabricates the whole RM4,000 relief and understates tax by roughly RM960.
            return .provesNothing

        case (.employeesProvidentFund, .other, _):
            candidate = epfNonMalaysian

        case (.socialSecurity, _, .atOrAbove):
            // Category 2 pays no employee share at all — Act 4 s.6(5), "wholly by the
            // employer" — and it covers anyone who first contributed at 55 or over as
            // well as everyone aged 60 or over. Relio cannot know when someone first
            // contributed, so from 55 the admissible contributors include one who pays
            // nothing. EIS's own exclusions, at 60 and for anyone starting at 57, sit
            // inside that and need no rule of their own.
            return .provesNothing

        case (.socialSecurity, .other, .below):
            // Whether EIS covers a non-citizen employee is not settled here, and the
            // combined ladder overstates if it does not. Unsettled resolves downward.
            return .provesNothing

        case (.socialSecurity, .malaysianCitizen, .below),
             (.socialSecurity, .permanentResident, .below):
            guard let era = socialSecurityLadders.first(where: { $0.covers(month) }) else {
                return .provesNothing
            }
            candidate = era
        }
        return candidate.covers(month) ? candidate : .provesNothing
    }

    // MARK: - EPF, Employees Provident Fund Act 1991, Third Schedule

    private static let epfSource = URL(
        string: "https://www.kwsp.gov.my/en/employer/responsibilities/contribution")!

    /// The Third Schedule's opening band pays nothing at all, so a rate applied to a wage
    /// inside it would claim a sen the schedule does not pay.
    private static let epfNilBandTop = Money(sen: 1_001)

    /// Part A — Malaysian citizens and permanent residents under 60. Unchanged across
    /// YA2023, YA2024 and YA2025, and unchanged by the schedule that replaced it on
    /// 1 October 2025.
    ///
    /// From July 2022 wages and not before. The employee rate was 9% on January 2021
    /// through June 2022 wages and returning to 11% took a form (KWSP 17A Khas), so Relio
    /// cannot know which rate a member paid in those months and 11% is not a floor there.
    static let epfUnderSixty = ContributionFloorTable(
        basis: .flatRate(Decimal(11) / Decimal(100), appliesAtOrAbove: epfNilBandTop),
        effectiveFrom: WageMonth(year: 2022, month: 7),
        sourceURL: epfSource)

    /// Part C — permanent residents aged 60 or over. Half the rate, not none: a citizen's
    /// exemption at 60 does not reach them.
    static let epfPermanentResidentAtSixty = ContributionFloorTable(
        basis: .flatRate(Decimal(55) / Decimal(1_000), appliesAtOrAbove: epfNilBandTop),
        effectiveFrom: WageMonth(year: 2022, month: 7),
        sourceURL: epfSource)

    /// Part F — non-Malaysians, from 1 October 2025 wages. EPF was voluntary for them
    /// before that, so earlier months prove nothing rather than 11%.
    static let epfNonMalaysian = ContributionFloorTable(
        basis: .flatRate(Decimal(2) / Decimal(100), appliesAtOrAbove: epfNilBandTop),
        effectiveFrom: WageMonth(year: 2025, month: 10),
        sourceURL: URL(
            string: "https://www.kwsp.gov.my/en/employer/responsibilities/non-malaysian-citizen-employees")!)

    // MARK: - Social security, Act 4 and Act 800

    private static let socialSecuritySource = URL(
        string: "https://www.perkeso.gov.my/en/contribution-rate.html")!

    /// SOCSO Category 1 plus EIS, employee shares, 0.5% and 0.2%.
    private static let combinedEmployeeRate = Decimal(7) / Decimal(1_000)

    /// The two insured-wage ceiling eras in force across YA2023 to YA2025.
    ///
    /// The ceiling is keyed to the wage month and moved inside YA2024, which is the whole
    /// reason these tables are not in the rulebook. Wage months before September 2022 fall
    /// outside both eras and prove nothing; YA2023's earliest reachable wage month is
    /// December 2022, so nothing in scope is lost.
    static let socialSecurityLadders: [ContributionFloorTable] = [
        ContributionFloorTable(
            basis: .stepLadder(ladder(ceilingRinggit: 5_000, atCeiling: Money(sen: 3_465))),
            effectiveFrom: WageMonth(year: 2022, month: 9),
            effectiveThrough: WageMonth(year: 2024, month: 9),
            sourceURL: socialSecuritySource),
        ContributionFloorTable(
            basis: .stepLadder(ladder(ceilingRinggit: 6_000, atCeiling: Money(sen: 4_165))),
            effectiveFrom: WageMonth(year: 2024, month: 10),
            sourceURL: socialSecuritySource),
    ]

    /// The employee's combined share, band by band, generated rather than transcribed.
    ///
    /// Both schedules print an amount per band, and the amount is a rounding of a rate on
    /// the band's *assumed* wage — its midpoint — not on the wage actually earned. So a
    /// rate on the actual wage is not a floor: at RM600 a month the band runs from RM500,
    /// its assumed wage is RM550, and the schedules pay RM2.75 plus RM1.10, where 0.7% of
    /// RM600 would be RM4.20. Flooring the rate does not rescue it either, because the
    /// printed rounding is irregular in both directions — SOCSO's fourth band rounds
    /// RM0.425 down to RM0.40 while EIS rounds RM0.17 up to RM0.20 — so a generated figure
    /// can still land above a printed one.
    ///
    /// What is safe is the rate on the band's *lower* limit, which the assumed wage always
    /// sits above. That is not a general inequality: the printed amounts are granular to
    /// five sen, and in the narrowest bands the rounding loss eats more than the gap
    /// between the lower limit and the midpoint gains. So `StatutoryContributionFloorTests`
    /// checks it band by band across the whole wage range, against the least either
    /// schedule can print, rather than the claim being asserted in prose here.
    ///
    /// The top rung is the insured-wage ceiling instead, where the published figure is
    /// exact and holds for every higher wage: RM24.75 plus RM9.90 at the RM5,000 ceiling,
    /// RM29.75 plus RM11.90 at RM6,000.
    private static func ladder(ceilingRinggit: Int,
                               atCeiling: Money) -> [ContributionFloorTable.Step] {
        // The schedules widen the bands as the wage rises — RM30, then RM20, RM30, RM40,
        // RM60 — and settle at RM100 from RM200 up to the ceiling.
        let lowerLimits = [0, 30, 50, 70, 100, 140]
            + Array(stride(from: 200, to: ceilingRinggit, by: 100))

        return lowerLimits.map { limit in
            let lower = Money(sen: limit * 100)
            return ContributionFloorTable.Step(
                monthlyWageAtLeast: Money(sen: lower.sen + 1),
                employeeFloor: limit == ceilingRinggit - 100
                    ? atCeiling
                    : lower.applying(combinedEmployeeRate, rounding: .down))
        }
    }

    // MARK: - Which wage months a Year of Assessment can draw on

    /// When a contribution counts toward a Year of Assessment.
    ///
    /// Genuinely unresolved. Para 46(1)(n) relieves a contribution "made or suffered in
    /// that basis year"; Act 812's 2019 redraft of s.49(1) dropped the equivalent clause
    /// for EPF. A January wage is remitted in February and the member statement records by
    /// credit month, so the two readings differ by one month at each year boundary.
    ///
    /// Relio does not pick one. `ContributionDerivation` computes the year's floor under
    /// both and keeps the smaller, which is a floor whichever reading is right. For a
    /// steady twelve-month salary the two agree exactly, so the dominant case pays nothing
    /// for the caution.
    enum BasisYearReading: Hashable, Sendable, CaseIterable {
        case wagesInYear
        case remittedInYear
    }

    /// The twelve wage months a Year of Assessment draws on, under one reading.
    static func wageMonths(inYear year: Int, reading: BasisYearReading) -> [WageMonth] {
        switch reading {
        case .wagesInYear:
            (1...12).map { WageMonth(year: year, month: $0) }
        case .remittedInYear:
            [WageMonth(year: year - 1, month: 12)]
                + (1...11).map { WageMonth(year: year, month: $0) }
        }
    }
}

extension ContributionScheme {
    /// The age at which the scheme's rate changes, and from which Relio's floor is the
    /// smaller of the two regimes.
    var ageThreshold: Int {
        switch self {
        case .employeesProvidentFund: 60
        case .socialSecurity: 55
        }
    }
}
