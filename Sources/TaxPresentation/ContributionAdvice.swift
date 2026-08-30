import Foundation
import TaxKit
import TaxData

/// A figure Relio is willing to put in front of the user, and how sure of it it is.
public struct ContributionSuggestion: Hashable, Sendable {

    public enum Confidence: Hashable, Sendable {
        /// The proven floor reaches the cap, so the relief *is* the cap and one tap adds it.
        case exactlyTheCap
        /// A proven lower bound below the cap. The affordance opens the entry editor
        /// prefilled rather than adding outright, because Relio has just told the user this
        /// is not the whole of it. The affordance encodes the certainty.
        case atLeast
    }

    public let code: ReliefCode
    public let amount: Money
    public let confidence: Confidence
    public let basis: [ContributionBasis]
    public let sourceURLs: [URL]
    /// The identity the accepted entry must carry, taken from the estimate.
    public let entryID: UUID
}

/// What a proven contribution floor lets Relio say on a relief screen.
public enum ContributionAdvice: Hashable, Sendable {
    case none
    case offer(ContributionSuggestion)
    /// `worth` is the assessment's own `taxSaved` — what the engine already computes for an
    /// unclaimed relief's headroom. The prompt can say what answering is worth without a
    /// second tax figure being computed anywhere in this feature.
    case answer([ContributionQuestion], worth: Money?)
    case crossCheck(logged: Money, provenFloor: Money)

    /// The single place the rule lives.
    ///
    /// Pure: no store, no clock, no actor, so every branch is a table-driven test.
    /// `ReliefDetailViewModel` calls this and renders the result; it re-derives no part of
    /// it.
    ///
    /// The cross-check fires in one direction only. A floor can prove that someone claimed
    /// too little; it can never prove they claimed too much, because the true contribution
    /// is somewhere above the floor and nothing bounds it from the other side. So Relio
    /// never tells a user their own figure is too high.
    public static func advise(estimate: ContributionEstimate,
                              assessment: ReliefAssessment,
                              loggedEntries: [EntryDraft]) -> ContributionAdvice {
        // Only `.ineligible` silences the screen. `.needsInfo` is the engine's "nobody has
        // asked yet", and treating it as a refusal would cost the user a relief over a
        // question that was never put to them.
        if case .ineligible = assessment.eligibility { return .none }

        if !loggedEntries.isEmpty {
            guard let annualFloor = estimate.annualFloor else { return .none }
            let logged = loggedEntries.reduce(Money.zero) { $0 + $1.amount }
            // Clamped to the cap, because a floor above the cap proves nothing about a
            // claim that is already at the statutory limit — the card would fire with
            // nothing for the user to fix. Clamping only ever lowers the floor, so it can
            // never manufacture an under-claim that is not there.
            let proven = annualFloor.clamped(to: assessment.cap)
            guard logged < proven else { return .none }
            return .crossCheck(logged: logged, provenFloor: proven)
        }

        switch estimate.certainty(against: assessment.cap) {
        case .exactlyTheCap(let cap):
            return .offer(suggestion(from: estimate, amount: cap, confidence: .exactlyTheCap))
        case .atLeast(let floor):
            return .offer(suggestion(from: estimate, amount: floor, confidence: .atLeast))
        case .blocked(let missing):
            return .answer(missing, worth: assessment.taxSaved)
        case .noWageRecords:
            return .none
        }
    }

    private static func suggestion(from estimate: ContributionEstimate,
                                   amount: Money,
                                   confidence: ContributionSuggestion.Confidence)
        -> ContributionSuggestion {
        ContributionSuggestion(code: estimate.scheme.reliefCode,
                               amount: amount,
                               confidence: confidence,
                               basis: estimate.basis,
                               sourceURLs: estimate.sourceURLs,
                               entryID: estimate.acceptedEntryID)
    }
}

/// One router for both kinds of question, so the App has one sheet and not two.
///
/// The two-owner split stays real: `ProfileQuestion` is TaxKit's vocabulary of rulebook
/// eligibility predicates and `ContributionQuestion` is TaxData's vocabulary of payroll
/// facts, and neither module should learn the other's. It just does not need to reach the
/// view layer, which has one list to render either way.
public enum AnswerableQuestion: Hashable, Sendable {
    case profile(ProfileQuestion)
    case contribution(ContributionQuestion)
}
