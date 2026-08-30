import Foundation
import TaxKit

/// A statutory contribution Relio can prove a floor for from the income timeline.
public enum ContributionScheme: String, Hashable, Sendable, CaseIterable {

    /// The employee's share of EPF, relieved under ITA s.49(1)(b).
    case employeesProvidentFund

    /// The employee's shares of SOCSO **and** EIS together.
    ///
    /// One scheme rather than two because para 46(1)(n) relieves both Acts under a single
    /// figure, and the two are always deducted together. Splitting them would make two
    /// floors that only ever get added back up, and two chances to disagree about which
    /// insured-wage ceiling was in force. LHDN's English web table omits EIS; the Malay
    /// table, Form BE and the Notes all name it, and this follows those.
    case socialSecurity

    /// The rulebook code this scheme's floor is evidence for.
    ///
    /// TaxData may name a `ReliefCode` — it depends on TaxKit — but never a cap. RM4,000
    /// and RM350 live in the rulebook JSON and nowhere else, so a Budget that moves either
    /// costs no edit here.
    public var reliefCode: ReliefCode {
        switch self {
        case .employeesProvidentFund: .epfContribution
        case .socialSecurity: .socsoEis
        }
    }

    /// Whether this source deducts for the scheme, as the user answered it.
    ///
    /// Three-valued all the way down. `nil` is "not asked yet" and `false` is "confirmed
    /// no deductions"; both contribute nothing to a floor, and only `nil` is worth asking
    /// about. Reading `nil` as `true` is the silent assumption the flag exists to prevent.
    func deduction(in source: IncomeSourceSnapshot) -> Bool? {
        switch self {
        case .employeesProvidentFund: source.deductsEPF
        case .socialSecurity: source.deductsSOCSO
        }
    }
}
