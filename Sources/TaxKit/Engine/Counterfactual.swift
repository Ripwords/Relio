import Foundation

/// One relief whose treatment differs between two rulebooks, priced against the user's
/// own entries.
public struct CounterfactualLine: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var allowedUnderBaseline: Money
    public var allowedUnderComparison: Money
    /// Positive when the baseline year is better for this user.
    public var difference: Money

    public var id: ReliefCode { code }
}

public struct CounterfactualResult: Hashable, Sendable {
    public var baselineYA: Int
    public var comparisonYA: Int
    /// Only reliefs whose allowed amount actually differs, biggest difference first.
    public var lines: [CounterfactualLine]
    public var totalReliefDifference: Money
    /// Difference in estimated tax, `comparison - baseline`. Positive means the
    /// baseline year leaves the user better off — the same convention as `difference`
    /// and `totalReliefDifference`. `nil` when income is unknown.
    public var taxDifference: Money?
}

/// Replays the same entries under two rulebooks and reports the difference in ringgit.
///
/// This is the version of year comparison worth showing: not "the cap went up" but
/// "the cap going up is worth RM 1,680 to you". It costs almost nothing to build because
/// `evaluate` is pure — the only change is which ruleset is passed in.
public func counterfactual(entries: [EntrySnapshot],
                           year: TaxYearSnapshot,
                           under baseline: RuleSet,
                           versus comparison: RuleSet) -> CounterfactualResult {

    let base = evaluate(ruleSet: baseline, year: year, entries: entries)
    let other = evaluate(ruleSet: comparison, year: year, entries: entries)

    let otherByCode = Dictionary(uniqueKeysWithValues:
        other.allAssessments.map { ($0.code, $0) })

    var lines: [CounterfactualLine] = []
    for assessment in base.allAssessments {
        let comparisonAllowed = otherByCode[assessment.code]?.allowed ?? .zero
        guard assessment.allowed != comparisonAllowed else { continue }
        lines.append(CounterfactualLine(
            code: assessment.code,
            name: assessment.name,
            allowedUnderBaseline: assessment.allowed,
            allowedUnderComparison: comparisonAllowed,
            difference: assessment.allowed - comparisonAllowed))
    }

    // A relief that exists only in the comparison year is a loss under the baseline.
    let baseCodes = Set(base.allAssessments.map(\.code))
    for assessment in other.allAssessments where !baseCodes.contains(assessment.code) {
        guard assessment.allowed != .zero else { continue }
        lines.append(CounterfactualLine(
            code: assessment.code,
            name: assessment.name,
            allowedUnderBaseline: .zero,
            allowedUnderComparison: assessment.allowed,
            difference: Money.zero - assessment.allowed))
    }

    // Swift's sort is not stable, and ties are reachable: DISABLED_SELF,
    // DISABLED_SPOUSE and INSURANCE_EDU_MEDICAL all moved by exactly RM 1,000 between
    // YA2024 and YA2025. Without a tie-break the Compare screen could reorder between
    // launches, so equal magnitudes fall back to the code.
    lines.sort {
        abs($0.difference.sen) == abs($1.difference.sen)
            ? $0.code.rawValue < $1.code.rawValue
            : abs($0.difference.sen) > abs($1.difference.sen)
    }

    var taxDifference: Money?
    if let baseTax = base.estimatedTax, let otherTax = other.estimatedTax {
        taxDifference = otherTax - baseTax
    }

    return CounterfactualResult(
        baselineYA: baseline.yearOfAssessment,
        comparisonYA: comparison.yearOfAssessment,
        lines: lines,
        totalReliefDifference: lines.reduce(Money.zero) { $0 + $1.difference },
        taxDifference: taxDifference)
}
