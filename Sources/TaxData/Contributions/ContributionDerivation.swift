import Foundation
import TaxKit

/// What one source contributed to a year's floor, so a screen can say *why*.
public struct ContributionBasis: Hashable, Sendable, Identifiable {
    public let sourceID: UUID
    public let name: String
    /// The first and last wage month that contributed. Gaps inside the range are not
    /// shown: "January to December 2024" is a summary, not a claim about every month in
    /// it. `nil` when no month of this source proved anything.
    public let months: ClosedRange<WageMonth>?
    public let floor: Money
    public var id: UUID { sourceID }

    public init(sourceID: UUID, name: String,
                months: ClosedRange<WageMonth>?, floor: Money) {
        self.sourceID = sourceID
        self.name = name
        self.months = months
        self.floor = floor
    }
}

/// The greatest annual employee contribution Relio can prove, and what stands in the way
/// of proving more.
public struct ContributionEstimate: Hashable, Sendable {
    public let scheme: ContributionScheme
    public let year: Int

    /// A **lower bound**, never a point estimate. Every approximation behind it rounds
    /// down, drops ambiguous income and resolves every unsettled statutory question toward
    /// the smaller figure, so the true contribution is always at least this.
    ///
    /// `nil` when no recurring wage reaches the year at all — the distinction
    /// `knownAnnualGross` draws, for the same reason. RM 0.00 is a claim that nothing was
    /// contributed; silence is not that claim.
    public let annualFloor: Money?

    /// Answers that would raise the floor, in a stable order.
    public let missing: [ContributionQuestion]

    /// Per source, ordered by name then id, the order `IncomeDerivation.totals` uses.
    public let basis: [ContributionBasis]

    /// The statutory rows behind the figures, for a "where this comes from" link.
    public let sourceURLs: [URL]

    public init(scheme: ContributionScheme, year: Int, annualFloor: Money?,
                missing: [ContributionQuestion], basis: [ContributionBasis],
                sourceURLs: [URL]) {
        self.scheme = scheme
        self.year = year
        self.annualFloor = annualFloor
        self.missing = missing
        self.basis = basis
        self.sourceURLs = sourceURLs
    }

    /// The floor read against a cap.
    ///
    /// The cap is a parameter, taken from an evaluated `ReliefAssessment`, and is never
    /// stored here: RM4,000 and RM350 live in the rulebook JSON and nowhere else.
    ///
    /// Reaching the cap settles the relief before an unanswered question can block it. No
    /// answer can raise a relief that is already at its limit, so once the floor is there
    /// nothing is worth asking for.
    public func certainty(against cap: Money) -> Certainty {
        guard let annualFloor else { return .noWageRecords }
        if cap <= annualFloor { return .exactlyTheCap(cap) }
        if !missing.isEmpty { return .blocked(missing: missing) }
        return .atLeast(annualFloor)
    }
}

public enum Certainty: Hashable, Sendable {
    /// The floor reaches the cap, so the relief is the cap **exactly**. Whatever the true
    /// contribution is, it is at least the floor, and every figure at or above the floor
    /// clamps to the same number. A proof, not an estimate.
    case exactlyTheCap(Money)
    /// A proven lower bound below the cap. Offered as a starting figure, never claimed on
    /// the user's behalf.
    case atLeast(Money)
    /// Nothing more is proven yet, and these answers would change that.
    case blocked(missing: [ContributionQuestion])
    /// No recurring wage reaches this year. Checked first: there is no point asking for a
    /// date of birth to price a salary nobody has recorded.
    case noWageRecords
}

/// Turns an income timeline into the floor under a year's statutory contributions.
///
/// Pure: no SwiftData, no actor, no clock, no `Double`. The year is a parameter, exactly
/// as it is for `IncomeDerivation` and `AgeCalculator`, so a figure proved today cannot
/// change tomorrow.
public enum ContributionDerivation {

    /// The greatest contribution the records prove for `year`.
    ///
    /// Contributions are computed **per employment** and only then summed under one relief
    /// cap, so this walks each source separately and never aggregates wages first.
    /// Aggregating errs in both directions — two RM3,000 salaries sit in an ordinary band
    /// each, where one RM6,000 salary would sit at the insured-wage ceiling.
    ///
    /// A source contributes only when its flag for the scheme is `true`. `nil` ("not asked
    /// yet") and `false` ("confirmed no deductions") both contribute nothing: different
    /// meanings for the user, identical arithmetic, and only `nil` is worth a question.
    ///
    /// One-off income is left out of every wage base. A one-off could be a bonus (EPF
    /// wages but not social security wages), overtime (the reverse) or a travel allowance
    /// (neither), and Relio cannot tell them apart. Leaving them out lowers the floor,
    /// which keeps the bound valid; guessing could raise it, which would not.
    public static func estimate(scheme: ContributionScheme,
                                year: Int,
                                from sources: [IncomeSourceSnapshot],
                                profile: ContributorProfile) -> ContributionEstimate {
        let ordered = sources.sorted { left, right in
            if left.name != right.name { return left.name < right.name }
            return left.id.uuidString < right.id.uuidString
        }

        // The slices arrive already rounded, so summing a month's recovers that month's
        // wage to the sen — which is what a mid-month raise otherwise loses.
        let wages = ordered.map { source in
            (source: source, byMonth: recurringWages(for: year, from: source))
        }

        let inYear = Set(StatutoryContributionFloors.wageMonths(inYear: year,
                                                                reading: .wagesInYear))
        let speaking = wages
            .filter { $0.byMonth.keys.contains(where: inYear.contains) }
            .map { ($0.source, $0.byMonth) }
        guard !speaking.isEmpty else {
            return ContributionEstimate(scheme: scheme, year: year, annualFloor: nil,
                                        missing: [], basis: [], sourceURLs: [])
        }

        // Each reading is totalled across every source before the two are compared.
        // Taking the smaller per source and summing those would be a floor too, but a
        // looser one: the statute settles on one reading for the whole return, not one per
        // employer.
        let byWageMonth = walk(scheme: scheme, year: year, reading: .wagesInYear,
                               profile: profile, wages: speaking)
        let byRemittance = walk(scheme: scheme, year: year, reading: .remittedInYear,
                                profile: profile, wages: speaking)
        let proven = byRemittance.total < byWageMonth.total ? byRemittance : byWageMonth

        return ContributionEstimate(
            scheme: scheme, year: year, annualFloor: proven.total,
            missing: questions(scheme: scheme, profile: profile, inYear: inYear,
                               wages: speaking),
            basis: proven.basis, sourceURLs: proven.sourceURLs)
    }

    /// This source's recurring wage per month, over every month a basis-year reading can
    /// reach: December of the year before through December of the year.
    private static func recurringWages(for year: Int,
                                       from source: IncomeSourceSnapshot) -> [WageMonth: Money] {
        let reachable = Set(StatutoryContributionFloors.BasisYearReading.allCases
            .flatMap { StatutoryContributionFloors.wageMonths(inYear: year, reading: $0) })

        var byMonth: [WageMonth: Money] = [:]
        for slice in IncomeDerivation.monthlyContributions(for: year - 1, from: source)
            + IncomeDerivation.monthlyContributions(for: year, from: source)
            where slice.origin == .recurringRate && reachable.contains(slice.month) {
            byMonth[slice.month] = (byMonth[slice.month] ?? .zero) + slice.amount
        }
        return byMonth
    }

    private struct Tally {
        var total = Money.zero
        var basis: [ContributionBasis] = []
        var sourceURLs: [URL] = []
    }

    private static func walk(scheme: ContributionScheme,
                             year: Int,
                             reading: StatutoryContributionFloors.BasisYearReading,
                             profile: ContributorProfile,
                             wages: [(IncomeSourceSnapshot, [WageMonth: Money])]) -> Tally {
        let window = Set(StatutoryContributionFloors.wageMonths(inYear: year, reading: reading))
        var tally = Tally()

        for (source, byMonth) in wages where scheme.deduction(in: source) == true {
            var floor = Money.zero
            var proving: [WageMonth] = []

            for (month, wage) in byMonth.sorted(by: { $0.key < $1.key })
                where window.contains(month) {
                let rule = StatutoryContributionFloors.floorRule(scheme: scheme,
                                                                 profile: profile, month: month)
                let monthly = rule.table.employeeFloor(forMonthlyWage: wage)
                guard monthly > .zero else { continue }
                floor = floor + monthly
                proving.append(month)
                if let url = rule.table.sourceURL, !tally.sourceURLs.contains(url) {
                    tally.sourceURLs.append(url)
                }
            }

            tally.total = tally.total + floor
            tally.basis.append(ContributionBasis(
                sourceID: source.id, name: source.name,
                months: proving.first.flatMap { first in proving.last.map { first...$0 } },
                floor: floor))
        }
        return tally
    }

    /// The answers that would raise the floor.
    ///
    /// Asked only about sources that actually paid a wage in the year, and asked as a set:
    /// confirming that a job deducts EPF proves nothing on its own while the rate still
    /// depends on facts nobody has been asked for, so the profile questions ride along
    /// with the unasked sources as well as the confirmed ones.
    private static func questions(scheme: ContributionScheme,
                                  profile: ContributorProfile,
                                  inYear: Set<WageMonth>,
                                  wages: [(IncomeSourceSnapshot, [WageMonth: Money])])
        -> [ContributionQuestion] {

        var profileQuestions: [ContributionQuestion] = []
        var sourceQuestions: [ContributionQuestion] = []

        for (source, byMonth) in wages {
            let answer = scheme.deduction(in: source)
            guard answer != false else { continue }
            if answer == nil {
                sourceQuestions.append(.sourceDeducts(scheme: scheme, sourceID: source.id))
            }
            for month in byMonth.keys.filter(inYear.contains).sorted() {
                for question in StatutoryContributionFloors.floorRule(
                    scheme: scheme, profile: profile, month: month).missing
                    where !profileQuestions.contains(question) {
                    profileQuestions.append(question)
                }
            }
        }
        return profileQuestions + sourceQuestions
    }
}
