import Foundation
import TaxKit

/// The whole sum, from gross income down to the tax owed.
///
/// TaxKit has computed `chargeableIncome` and `estimatedTax` since the first plan, the
/// golden files assert both, and no screen in the app showed either. Home led with what is
/// still claimable — the last line of the calculation — and never said what the user would
/// actually pay, which is the question they open a tax app with.
///
/// A value built from one evaluation, with no store and no actor, so it is testable
/// without a simulator like everything else in this package.
public struct TaxSummary: Hashable, Sendable {

    /// What the year's income adds up to. Derived rather than read: the evaluation carries
    /// the figure after relief, and the relief it allowed, and gross is the two put back
    /// together — which keeps this consistent with the numbers beside it by construction.
    public let grossIncome: Money
    public let reliefAllowed: Money
    public let chargeableIncome: Money
    public let estimatedTax: Money
    /// What using every remaining headroom would take off the tax above. `nil` only when
    /// the engine could not compute it.
    public let stillClaimable: Money?

    /// `nil` when income is unknown.
    ///
    /// Income is optional in Relio, and every tax figure the engine produces is `nil`
    /// without it. Filling those in with zeroes would tell someone who has recorded no
    /// income that they owe no tax, which is a different claim from "not known".
    public init?(_ result: EvaluationResult) {
        guard let chargeable = result.chargeableIncome,
              let tax = result.estimatedTax else { return nil }
        self.chargeableIncome = chargeable
        self.estimatedTax = tax
        self.reliefAllowed = result.totalAllowed
        self.grossIncome = chargeable + result.totalAllowed
        self.stillClaimable = result.totalOpportunity
    }
}
