import Foundation
import TaxKit

/// The greatest employee contribution provable from a monthly wage, under one scheme, for
/// one contributor class, during one statutory era.
///
/// Every lookup is a lower bound on what the schedules actually pay, never a point
/// estimate. That is the property the whole feature rests on, and it is what makes the
/// dominant case exact: once a year's floor reaches the relief cap, the relief is the cap,
/// because every figure at or above the floor clamps to the same number.
public struct ContributionFloorTable: Hashable, Sendable {

    /// One rung of a step ladder.
    public struct Step: Hashable, Sendable {
        /// A statutory band's inclusive lower limit — RM30.01 for the band that runs to
        /// RM50. Keying on the lower limit rather than the upper is what makes the rung
        /// safe: every wage inside a band reads that band's own amount, and a wage sitting
        /// exactly on a band's upper limit cannot reach up into the next band's.
        public let monthlyWageAtLeast: Money
        public let employeeFloor: Money

        public init(monthlyWageAtLeast: Money, employeeFloor: Money) {
            self.monthlyWageAtLeast = monthlyWageAtLeast
            self.employeeFloor = employeeFloor
        }
    }

    /// How a monthly wage becomes a floor.
    ///
    /// One case per statutory shape rather than a rung list plus an optional rate. A table
    /// carrying both would have to say which one wins where, and the two answers differ by
    /// more than the guarantee tolerates: a flat 0.7% of a RM600 social-security wage is
    /// RM4.20, where the schedules pay RM3.85 on that band's RM550 assumed wage. The
    /// combination has to be unrepresentable, not merely unused.
    public enum Basis: Hashable, Sendable {

        /// A flat rate on the whole wage, rounded **down** to the sen, for wages at or
        /// above `appliesAtOrAbove`.
        ///
        /// A floor because the EPF Third Schedule pays `ceil(rate × band upper limit)` and
        /// a band's upper limit is at or above every wage in it, so a rate on the actual
        /// wage cannot climb past the printed amount. `appliesAtOrAbove` is the top of the
        /// schedule's opening NIL band, where it pays nothing at all and a rate applied to
        /// the wage would exceed the truth by a sen.
        case flatRate(Decimal, appliesAtOrAbove: Money)

        /// Rungs in ascending order of `monthlyWageAtLeast`, with non-decreasing
        /// `employeeFloor`. The highest rung is the insured-wage ceiling and holds at
        /// every wage above it, because the wage insured is capped there.
        case stepLadder([Step])

        /// Nothing about this wage month is provable.
        case nothing
    }

    public let basis: Basis
    public let effectiveFrom: WageMonth
    /// `nil` while the era is the current one.
    public let effectiveThrough: WageMonth?
    /// Every shipped statutory figure carries its source, exactly as `ReliefRule` does.
    /// `nil` only on `provesNothing`, which states no figure and so cites none.
    public let sourceURL: URL?

    public init(basis: Basis,
                effectiveFrom: WageMonth,
                effectiveThrough: WageMonth? = nil,
                sourceURL: URL? = nil) {
        self.basis = basis
        self.effectiveFrom = effectiveFrom
        self.effectiveThrough = effectiveThrough
        self.sourceURL = sourceURL
    }

    /// Whether this table governs `month`.
    public func covers(_ month: WageMonth) -> Bool {
        guard effectiveFrom <= month else { return false }
        guard let effectiveThrough else { return true }
        return month <= effectiveThrough
    }

    /// The greatest employee contribution provable from one month's wage.
    ///
    /// Total. A wage no rung reaches yields `.zero`, which is a floor of nothing rather
    /// than an error: there is no wage this cannot answer for, and no answer it can give
    /// that is above the truth.
    public func employeeFloor(forMonthlyWage wage: Money) -> Money {
        guard wage > .zero else { return .zero }
        switch basis {
        case let .flatRate(rate, appliesAtOrAbove):
            guard appliesAtOrAbove <= wage else { return .zero }
            return wage.applying(rate, rounding: .down)
        case let .stepLadder(steps):
            return steps.last(where: { $0.monthlyWageAtLeast <= wage })?.employeeFloor ?? .zero
        case .nothing:
            return .zero
        }
    }

    /// The table for a contributor, a scheme or a month Relio cannot pin down.
    ///
    /// The era is nominal. Refusing to prove anything is available in every month, and
    /// `StatutoryContributionFloors` returns this directly rather than era-selecting it.
    public static let provesNothing = ContributionFloorTable(
        basis: .nothing, effectiveFrom: WageMonth(year: 1, month: 1))
}
