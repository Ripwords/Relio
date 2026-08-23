import Foundation

/// Three-valued, mirroring `PredicateOutcome`. `needsInfo` is the case that earns its
/// keep: treating an unanswered question as ineligibility silently costs the user money.
public enum Eligibility: Hashable, Sendable {
    case eligible
    case ineligible(reasons: [String])
    case needsInfo(questions: [ProfileQuestion])

    public var isEligible: Bool { self == .eligible }
}

/// Whether a claim carries the documents LHDN asks for.
public struct RequirementCheck: Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        case satisfied
        /// The entries that are missing this document kind.
        case missing(entryIDs: [UUID])
    }

    public var kind: DocumentKind
    public var status: Status

    public var isSatisfied: Bool { status == .satisfied }
}

/// What the user can claim under one relief, and what it is worth.
public struct ReliefAssessment: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    /// The effective ceiling for this user, after tier selection and per-dependent
    /// multiplication.
    public var cap: Money
    /// What the user actually entered.
    public var claimed: Money
    /// What LHDN would allow — `claimed` capped, and further limited by any parent.
    public var allowed: Money
    /// `cap - allowed`, never negative.
    public var headroom: Money
    public var eligibility: Eligibility
    public var requirements: [RequirementCheck]
    /// Tax saved if the headroom were fully used. `nil` when income is unknown or the
    /// figure is unverified.
    public var taxSaved: Money?
    public var unverified: Bool
    public var sourceURL: URL
    public var notes: String?
    public var children: [ReliefAssessment]

    public var id: ReliefCode { code }

    /// This assessment and every descendant, depth-first.
    public var selfAndDescendants: [ReliefAssessment] {
        [self] + children.flatMap(\.selfAndDescendants)
    }
}

/// An entry whose code no rule in this year matches. Surfaced so the UI can show an
/// actionable amber row instead of dropping the claim.
public struct UnresolvedEntry: Hashable, Sendable {
    public enum Reason: Hashable, Sendable {
        case retired(supersededBy: ReliefCode?)
        case unknownInThisYear
    }

    public var entryID: UUID
    public var code: ReliefCode
    public var amount: Money
    public var reason: Reason
}

public struct EvaluationResult: Hashable, Sendable {
    public var yearOfAssessment: Int
    /// Top-level reliefs; sub-limits hang off their parents' `children`.
    public var assessments: [ReliefAssessment]
    public var unresolved: [UnresolvedEntry]
    /// Income after every allowed relief. `nil` when income is unknown.
    public var chargeableIncome: Money?
    /// Estimated tax on `chargeableIncome`. `nil` when income is unknown.
    public var estimatedTax: Money?

    /// Every assessment including nested sub-limits, depth-first.
    ///
    /// For lookup, not for totalling: a sub-limit's amount is already inside its
    /// parent's, so reducing this over `allowed` double-counts. Use `totalAllowed`.
    public var allAssessments: [ReliefAssessment] {
        assessments.flatMap(\.selfAndDescendants)
    }

    public func assessment(for code: ReliefCode) -> ReliefAssessment? {
        allAssessments.first { $0.code == code }
    }

    /// Total relief LHDN would allow. Counts top-level reliefs only, because a
    /// sub-limit's amount is already inside its parent's `allowed`.
    public var totalAllowed: Money {
        assessments.reduce(Money.zero) { $0 + $1.allowed }
    }
}
