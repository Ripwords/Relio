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

    // Two different totals, and the difference matters.
    //
    // `claimed` is what the user entered, raw, so the UI can show "you logged RM 1,500".
    // `allowed` aggregates each child's *capped* amount, because a sub-limit binds
    // before the parent ceiling does: RM 1,500 against the RM 1,000 medical check-up
    // sub-limit is RM 1,000 of relief, not RM 1,500. Summing children's raw claims here
    // would let the RM 500 a sub-limit already rejected go on to consume parent
    // headroom, overstating relief and understating tax.
    let claimedTotal = children.reduce(ownClaimed) { $0 + $1.claimed }
    let allowedFromChildren = children.reduce(Money.zero) { $0 + $1.allowed }

    let resolved = effectiveCap(rule.cap, rule: rule, year: year)
    let cap = resolved.cap
    let eligibility: Eligibility = resolved.missing.isEmpty
        ? .eligible
        : .needsInfo(questions: resolved.missing)      // Task 13 computes this properly

    // An automatic relief is granted in full once it is eligible — LHDN gives the
    // RM 9,000 individual relief to every resident, and child and spouse reliefs follow
    // from the household, not from a receipt.
    let granted = rule.automatic && eligibility.isEligible
    let claimed = granted ? cap : claimedTotal
    // Floored as well as capped: `clamped(to:)` only bounds the top, and a negative
    // entry (SSPN's net deposit can be negative) would otherwise push headroom above
    // the cap and inflate the opportunity figure. `ownClaimed` is floored before adding
    // children so the negative-SSPN floor still applies to the parent's own entries.
    let allowed = granted
        ? cap
        : max((max(ownClaimed, .zero) + allowedFromChildren).clamped(to: cap), .zero)
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

/// Resolves a declared cap into a concrete ceiling for this user, along with any
/// question that had to go unanswered to get there.
private func effectiveCap(_ cap: Cap,
                          rule: ReliefRule,
                          year: TaxYearSnapshot) -> (cap: Money, missing: [ProfileQuestion]) {
    switch cap {
    case .fixed(let amount):
        return (amount, [])

    case .perDependent(let perChild):
        // Each dependent is tested against this rule's own predicate, so
        // CHILD_TERTIARY counts only tertiary students and CHILD_UNDER_18 only under-18s.
        var total = Money.zero
        var missing: [ProfileQuestion] = []
        for dependent in year.dependents {
            var facts = year.facts(claimant: .child)
            facts.dependent = dependent.facts
            switch rule.eligibility?.evaluate(facts) ?? .satisfied {
            case .satisfied:
                total = total + perChild.applying(Decimal(dependent.claimPercentage) / 100)
            case .failed:
                continue
            case .unknown(let questions):
                missing.append(contentsOf: questions)
            }
        }
        return (total, missing.deduplicated())

    case .tiered(let fact, let tiers):
        let ordered = tiers.sorted { ($0.maxSen ?? .max) < ($1.maxSen ?? .max) }
        guard let value = year.value(of: fact) else {
            // Show the best case and ask, rather than hiding the relief behind a zero.
            return (ordered.map(\.amount).max() ?? .zero, [fact.question])
        }
        let selected = ordered.first { tier in tier.maxSen.map { value <= $0 } ?? true }
        return (selected?.amount ?? .zero, [])
    }
}

extension TieredFact {
    var question: ProfileQuestion {
        switch self {
        case .propertyPrice: .propertyPrice
        }
    }
}

extension TaxYearSnapshot {
    func value(of fact: TieredFact) -> Int? {
        switch fact {
        case .propertyPrice: propertyPriceSen
        }
    }

    /// The household facts, for a claim made in respect of `claimant`.
    func facts(claimant: Claimant?) -> Facts {
        Facts(yearOfAssessment: year,
              maritalStatus: maritalStatus,
              spouseHasIncome: spouseHasIncome,
              assessmentType: assessmentType,
              employmentType: employmentType,
              gender: gender,
              claimant: claimant,
              selfIsDisabled: selfIsDisabled,
              spouseIsDisabled: spouseIsDisabled)
    }
}
