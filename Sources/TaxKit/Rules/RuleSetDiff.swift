import Foundation

/// One published change between two Years of Assessment.
public enum ReliefDelta: Hashable, Sendable {
    case added(ReliefCode, name: String, cap: Money)
    case removed(ReliefCode, name: String, supersededBy: ReliefCode?)
    case capChanged(ReliefCode, name: String, from: Money, to: Money)
    case conditionsChanged(ReliefCode, name: String, from: String?, to: String?)

    public var code: ReliefCode {
        switch self {
        case .added(let c, _, _), .removed(let c, _, _),
             .capChanged(let c, _, _, _), .conditionsChanged(let c, _, _, _): c
        }
    }
}

/// The rule-level difference between two rulebooks, in stable code order.
///
/// This is the generic diff. The figure users care about comes from
/// `counterfactual(entries:year:under:versus:)`, which prices these changes against their
/// own spending.
public func diff(from earlier: RuleSet, to later: RuleSet) -> [ReliefDelta] {
    let before = Dictionary(uniqueKeysWithValues: earlier.allReliefs.map { ($0.code, $0) })
    let after = Dictionary(uniqueKeysWithValues: later.allReliefs.map { ($0.code, $0) })
    let successors = Dictionary(later.retiredCodes.map { ($0.retired, $0.supersededBy) },
                                uniquingKeysWith: { first, _ in first })

    var deltas: [ReliefDelta] = []

    for code in after.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
        let new = after[code]!
        guard let old = before[code] else {
            deltas.append(.added(code, name: new.name, cap: new.cap.nominalCeiling))
            continue
        }
        if old.cap.nominalCeiling != new.cap.nominalCeiling {
            deltas.append(.capChanged(code, name: new.name,
                                      from: old.cap.nominalCeiling,
                                      to: new.cap.nominalCeiling))
        }
        if old.eligibility != new.eligibility || old.requiredDocuments != new.requiredDocuments {
            deltas.append(.conditionsChanged(code, name: new.name,
                                             from: old.notes, to: new.notes))
        }
    }

    for code in before.keys.sorted(by: { $0.rawValue < $1.rawValue }) where after[code] == nil {
        deltas.append(.removed(code, name: before[code]!.name,
                               supersededBy: successors[code] ?? nil))
    }
    return deltas
}
