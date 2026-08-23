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
                                  estimatedTax: nil,
                                  totalOpportunity: nil)

    guard let gross = year.grossIncome else { return result }

    let chargeable = max(gross - result.totalAllowed, .zero)
    result.chargeableIncome = chargeable
    result.estimatedTax = ruleSet.brackets.tax(on: chargeable)

    // Second pass: tax figures need the chargeable income the first pass produced.
    result.assessments = result.assessments.map {
        withTaxSaved($0, chargeable: chargeable, brackets: ruleSet.brackets)
    }
    let combinedHeadroom = result.assessments
        .filter { $0.taxSaved != nil }
        .reduce(Money.zero) { $0 + $1.headroom }
    result.totalOpportunity = ruleSet.brackets.taxSaved(reducing: chargeable,
                                                        by: combinedHeadroom)
    return result
}

/// Fills `taxSaved` on an assessment and its descendants.
///
/// Sub-limits get a figure too, but their headroom is already inside the parent's, so
/// only top-level assessments contribute to `totalOpportunity`.
private func withTaxSaved(_ assessment: ReliefAssessment,
                          chargeable: Money,
                          brackets: BracketTable) -> ReliefAssessment {
    var updated = assessment
    updated.children = assessment.children.map {
        withTaxSaved($0, chargeable: chargeable, brackets: brackets)
    }

    let claimable: Bool = switch assessment.eligibility {
    case .eligible, .needsInfo: true      // needsInfo shows what answering is worth
    case .ineligible: false
    }
    updated.taxSaved = (claimable && !assessment.unverified)
        ? brackets.taxSaved(reducing: chargeable, by: assessment.headroom)
        : nil
    return updated
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
    // See Task 11: `claimed` is raw for display, `allowed` aggregates children's capped
    // amounts so a sub-limit's rejected excess cannot consume parent headroom.
    let claimedTotal = children.reduce(ownClaimed) { $0 + $1.claimed }
    let allowedFromChildren = children.reduce(Money.zero) { $0 + $1.allowed }

    let resolved = effectiveCap(rule.cap, rule: rule, year: year)
    let cap = resolved.cap

    // Eligibility must be settled before the grant decision: an automatic relief is
    // granted only when it is actually eligible, never while a question is outstanding.
    let eligibility = resolveEligibility(rule: rule,
                                         year: year,
                                         capQuestions: resolved.missing)
    let requirements = checkRequirements(rule: rule, entries: ownEntries)

    // A per-dependent cap has already excluded any dependent whose facts are
    // incomplete, so an outstanding question about one child must not withhold the
    // relief the household has already earned for another. Granting here cannot
    // overstate: the ambiguous dependent contributed nothing to `cap`.
    //
    // This exemption is only safe for per-dependent caps. A fixed automatic relief is
    // gated by its predicate as a whole — granting DISABLED_SELF while we still do not
    // know whether the taxpayer is registered disabled would overstate relief outright.
    let isPerDependentCap = if case .perDependent = rule.cap { true } else { false }
    let granted = rule.automatic && (eligibility.isEligible || isPerDependentCap)
    let claimed = granted ? cap : claimedTotal
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
                            requirements: requirements,
                            taxSaved: nil,
                            unverified: rule.unverified,
                            sourceURL: rule.sourceURL,
                            notes: rule.notes,
                            children: children)
}

/// Combines the rule's predicate with any question the cap could not be resolved without.
///
/// A per-dependent rule is deliberately exempt from the household-level predicate check:
/// its predicate is about each dependent, and `effectiveCap` has already applied it
/// per dependent. Re-running it here with no dependent in context would report a
/// spurious `.needsInfo`.
private func resolveEligibility(rule: ReliefRule,
                                year: TaxYearSnapshot,
                                capQuestions: [ProfileQuestion]) -> Eligibility {
    let isPerDependent = if case .perDependent = rule.cap { true } else { false }

    guard let predicate = rule.eligibility, !isPerDependent else {
        return capQuestions.isEmpty ? .eligible : .needsInfo(questions: capQuestions)
    }

    switch predicate.evaluate(year.facts(claimant: nil)) {
    case .satisfied:
        return capQuestions.isEmpty ? .eligible : .needsInfo(questions: capQuestions)
    case .failed(let reason):
        return .ineligible(reasons: [reason])
    case .unknown(let questions):
        return .needsInfo(questions: (questions + capQuestions).deduplicated())
    }
}

/// Set difference of the documents attached to each entry against the kinds the rule
/// requires. This is the whole of the requirement-check feature.
private func checkRequirements(rule: ReliefRule,
                               entries: [EntrySnapshot]) -> [RequirementCheck] {
    rule.requiredDocuments.map { kind in
        let lacking = entries.filter { !$0.documentKinds.contains(kind) }.map(\.id)
        return RequirementCheck(kind: kind,
                                status: lacking.isEmpty ? .satisfied
                                                        : .missing(entryIDs: lacking))
    }
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
