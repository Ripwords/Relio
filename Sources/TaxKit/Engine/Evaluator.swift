import Foundation

/// Turns a rulebook plus a user's year into per-relief assessments.
///
/// Pure: no I/O, no dates, no randomness, no SwiftData. The same inputs always produce
/// the same output, which is what makes the golden-file tests in Task 17 meaningful.
public func evaluate(ruleSet: RuleSet,
                     year: TaxYearSnapshot,
                     entries: [EntrySnapshot]) -> EvaluationResult {

    let known = Set(ruleSet.allReliefs.map(\.code))
    let retirements = Dictionary(
        ruleSet.retiredCodes.map { ($0.retired, $0.supersededBy) },
        uniquingKeysWith: { first, _ in first })

    // Entries whose code this year does not recognise never disappear; they are reported.
    var unresolved: [UnresolvedEntry] = []
    var usable: [EntrySnapshot] = []
    for entry in entries {
        if known.contains(entry.code) {
            usable.append(entry)
        } else if let successor = retirements[entry.code] {
            unresolved.append(UnresolvedEntry(entryID: entry.id, code: entry.code,
                                              amount: entry.amount,
                                              reason: .retired(supersededBy: successor)))
        } else {
            unresolved.append(UnresolvedEntry(entryID: entry.id, code: entry.code,
                                              amount: entry.amount,
                                              reason: .unknownInThisYear))
        }
    }

    let byCode = Dictionary(grouping: usable, by: \.code)
    let assessments = ruleSet.reliefs.map {
        assess(rule: $0, year: year, entriesByCode: byCode)
    }

    var result = EvaluationResult(yearOfAssessment: ruleSet.yearOfAssessment,
                                  assessments: assessments,
                                  unresolved: unresolved,
                                  chargeableIncome: nil,
                                  estimatedTax: nil)

    if let gross = year.grossIncome {
        let chargeable = max(gross - result.totalAllowed, .zero)
        result.chargeableIncome = chargeable
        result.estimatedTax = ruleSet.brackets.tax(on: chargeable)
    }
    return result
}

/// Assesses one rule and its sub-limits.
///
/// Cap kinds beyond `.fixed` arrive in Tasks 12 and 13; eligibility and requirements in
/// Task 14; `taxSaved` in Task 15.
private func assess(rule: ReliefRule,
                    year: TaxYearSnapshot,
                    entriesByCode: [ReliefCode: [EntrySnapshot]]) -> ReliefAssessment {

    let children = rule.children.map {
        assess(rule: $0, year: year, entriesByCode: entriesByCode)
    }

    let ownEntries = entriesByCode[rule.code] ?? []
    let ownClaimed = ownEntries.reduce(Money.zero) { $0 + $1.amount }
    let entered = children.reduce(ownClaimed) { $0 + $1.claimed }

    let cap = effectiveCap(rule.cap, year: year)
    let eligibility = Eligibility.eligible      // Task 13 computes this properly

    // An automatic relief is granted in full once it is eligible — LHDN gives the
    // RM 9,000 individual relief to every resident, and child and spouse reliefs follow
    // from the household, not from a receipt.
    let granted = rule.automatic && eligibility.isEligible
    let claimed = granted ? cap : entered
    // Floored as well as capped: `clamped(to:)` only bounds the top, and a negative
    // entry (SSPN's net deposit can be negative) would otherwise push headroom above
    // the cap and inflate the opportunity figure.
    let allowed = granted ? cap : max(entered.clamped(to: cap), .zero)
    let headroom = max(cap - allowed, .zero)

    return ReliefAssessment(code: rule.code,
                            name: rule.name,
                            cap: cap,
                            claimed: claimed,
                            allowed: allowed,
                            headroom: headroom,
                            eligibility: eligibility,
                            requirements: [],
                            taxSaved: nil,
                            unverified: rule.unverified,
                            sourceURL: rule.sourceURL,
                            notes: rule.notes,
                            children: children)
}

/// Resolves a declared cap into a concrete ceiling for this user.
/// Extended in Tasks 12 and 13.
private func effectiveCap(_ cap: Cap, year: TaxYearSnapshot) -> Money {
    switch cap {
    case .fixed(let amount):
        return amount
    case .perDependent(let amount):
        return amount
    case .tiered(_, let tiers):
        return tiers.map(\.amount).max() ?? .zero
    }
}
