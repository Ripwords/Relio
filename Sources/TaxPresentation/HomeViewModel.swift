import Foundation
import Observation
import TaxKit
import TaxData

/// What the headline number means. The label changes with it, because a relief figure
/// shown under a "tax saved" heading is a lie about money.
public enum HeadlineKind: Hashable, Sendable {
    case taxSaved
    case relief
}

public struct OpportunityRow: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var headroom: Money
    /// `nil` when income is unknown.
    public var taxSaved: Money?
    /// 0...100, integer arithmetic — the package bans `Double` outside charting.
    public var usedPercent: Int
    /// True for a `.needsInfo` relief, which renders as a question rather than a figure.
    public var needsAnswer: Bool

    /// See `ReliefRow.shortName`. Home has the least horizontal room of any screen, so a
    /// four-line row title costs it more than anywhere else.
    public var shortName: String { ReliefCopy.shortName(for: code, fullName: name) }

    public var id: ReliefCode { code }
}

public struct HomePrompts: Hashable, Sendable {
    /// The facts to ask about, not just how many there are: the prompt row is now a
    /// button, and the sheet it opens has to know what to put on screen.
    public var unansweredQuestions: [ProfileQuestion]
    /// Relief that would become claimable if those questions were answered favourably.
    public var unlockableRelief: Money
    public var claimsMissingDocuments: Int
    /// Entries whose code this year's rulebook does not recognise — retired, or from a
    /// rulebook that never shipped it.
    ///
    /// The evaluator reports these separately precisely so they can be surfaced: such an
    /// entry contributes to no assessment, so without this count the user's money is
    /// invisible on every screen in the app and their claim looks like it was never
    /// made. Rendering the actionable row is the reliefs screen's job; owning the number
    /// is this view model's.
    public var unresolvedEntryIDs: [UUID]

    public var unresolvedEntryCount: Int { unresolvedEntryIDs.count }

    public static let none = HomePrompts(unansweredQuestions: [],
                                         unlockableRelief: .zero,
                                         claimsMissingDocuments: 0,
                                         unresolvedEntryIDs: [])
}

/// Spec §11: Home answers one question — how much is being left on the table.
@MainActor
@Observable
public final class HomeViewModel {

    public let context: YearContext
    public private(set) var headline: Money = .zero
    public private(set) var headlineKind: HeadlineKind = .relief
    public private(set) var opportunities: [OpportunityRow] = []
    public private(set) var remainingOpportunityCount: Int = 0
    public private(set) var prompts: HomePrompts = .none

    /// Whether the user has logged anything at all this year.
    ///
    /// Gates the headline. With nothing logged every relief reports headroom equal to its
    /// cap, so the total is the rulebook's theoretical maximum rather than anything this
    /// person can claim — "RM 87,350.00 of relief still claimable" on a first launch.
    /// Home shows its first-run state instead, which is what spec §11.5 asked for and
    /// what the unreachable "Nothing logged yet" branch was already written to say.
    public private(set) var hasLoggedAnything = false

    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    /// The model behind the "answer N questions" prompt. Built here because this class
    /// holds both halves — the year context and the only thing allowed to write — and a
    /// view that had to be handed a store to build it would be one more place where the
    /// store leaks into the view layer.
    public func profileQuestions() -> ProfileQuestionsViewModel {
        ProfileQuestionsViewModel(context: context,
                                  store: store,
                                  questions: prompts.unansweredQuestions)
    }

    public func refresh() async {
        guard let result = context.result else {
            headline = .zero
            headlineKind = .relief
            opportunities = []
            remainingOpportunityCount = 0
            prompts = .none
            hasLoggedAnything = false
            return
        }

        let candidates = Self.rankedCandidates(in: result)

        if let total = result.totalOpportunity {
            headline = total
            headlineKind = .taxSaved
        } else {
            // No income, so no tax figure exists. Fall back to the relief still
            // available and let the view relabel.
            headline = candidates.reduce(Money.zero) { $0 + $1.headroom }
            headlineKind = .relief
        }

        opportunities = Array(candidates.prefix(3))
        remainingOpportunityCount = max(0, candidates.count - opportunities.count)
        prompts = await makePrompts(result)
        hasLoggedAnything = !((try? await store.entryDrafts(forYear: context.year)) ?? []).isEmpty
    }

    /// Eligible-or-unanswered reliefs with room left, best first.
    ///
    /// The eligibility filter comes first and is not negotiable: an `.ineligible` relief
    /// still reports `headroom` equal to its cap while `allowed` is zero, so a list built
    /// on headroom alone advertises reliefs the user cannot claim.
    static func rankedCandidates(in result: EvaluationResult) -> [OpportunityRow] {
        result.assessments
            .filter { assessment in
                if case .ineligible = assessment.eligibility { return false }
                return assessment.headroom > .zero
            }
            .map { assessment in
                var needsAnswer = false
                if case .needsInfo = assessment.eligibility { needsAnswer = true }
                return OpportunityRow(code: assessment.code,
                                      name: assessment.name,
                                      headroom: assessment.headroom,
                                      taxSaved: assessment.taxSaved,
                                      usedPercent: Self.percentUsed(assessment),
                                      needsAnswer: needsAnswer)
            }
            .sorted { left, right in
                // Claimability outranks value. A `.needsInfo` relief reports headroom
                // equal to its whole cap, so on a pure value sort it beats every relief
                // the user can actually claim — Home led with "Disabled individual,
                // RM 7,000" for a household that had never said anyone was disabled.
                // Its figure is what the relief would be worth if the answer went the
                // user's way, which is not the same kind of number as money already
                // sitting there, and sorting the two together implies it is.
                //
                // Still listed, per Plan 1: answering one question may recover real
                // money. Below the sure thing, and rendered as a question.
                if left.needsAnswer != right.needsAnswer { return right.needsAnswer }

                // Ties break on code. Plan 1 shipped a bug where equal-valued rows
                // reordered between launches; the fix is a total order, not a sort key.
                let leftValue = left.taxSaved ?? left.headroom
                let rightValue = right.taxSaved ?? right.headroom
                if leftValue != rightValue { return leftValue > rightValue }
                return left.code.rawValue < right.code.rawValue
            }
    }

    static func percentUsed(_ assessment: ReliefAssessment) -> Int {
        guard assessment.cap.sen > 0 else { return 0 }
        let percent = assessment.allowed.sen * 100 / assessment.cap.sen
        return min(100, max(0, percent))
    }

    private func makePrompts(_ result: EvaluationResult) async -> HomePrompts {
        // Distinct questions, and only the ones something can take an answer for.
        //
        // Counting `asked.count` per relief counted one question once per relief that
        // happened to be blocked on it: "answer 3 questions" for a household with a
        // single unanswered fact that three reliefs each needed. And a question with no
        // storage — `dependentDetails`, `lastClaimYear` — could never be driven off the
        // screen, so the prompt would sit there for ever however many the user answered.
        // `ProfileQuestionsViewModel.answerable` is the one list; the sheet asks it too.
        var asked: Set<ProfileQuestion> = []
        var unlockable = Money.zero
        for assessment in result.assessments {
            if case .needsInfo(let questions) = assessment.eligibility {
                let answerable = ProfileQuestionsViewModel.answerable(questions)
                guard !answerable.isEmpty else { continue }
                asked.formUnion(answerable)
                unlockable = unlockable + assessment.headroom
            }
        }
        // Stable order, so the sheet does not reshuffle its questions between openings.
        let questions = ProfileQuestion.allCases.filter(asked.contains)

        // Counted through the same function the Docs tab renders, for the same reason the
        // questions above are: the prompt is a button now, and a button whose number
        // disagrees with the screen it opens is worse than no button. `needsDocument` is
        // a per-entry flag the store maintains; the evaluator knows which kinds a relief
        // actually requires, and the two disagree whenever an entry is flagged against a
        // relief that requires nothing. Home said 8, the screen said 6.
        let entries = (try? await store.entryDrafts(forYear: context.year)) ?? []
        let missing = DocumentsViewModel.rows(in: result, entries: entries).count

        return HomePrompts(unansweredQuestions: questions,
                           unlockableRelief: unlockable,
                           claimsMissingDocuments: missing,
                           unresolvedEntryIDs: result.unresolved.map(\.entryID))
    }
}
