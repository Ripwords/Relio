import Foundation
import Observation
import TaxKit
import TaxData

@MainActor
@Observable
public final class ReliefDetailViewModel {

    public let code: ReliefCode
    public private(set) var assessment: ReliefAssessment?
    public private(set) var entries: [EntryDraft] = []
    public private(set) var subLimits: [ReliefAssessment] = []
    public private(set) var requirements: [RequirementCheck] = []
    public private(set) var sourceURL: URL?
    public private(set) var notes: String?
    public private(set) var advice: ContributionAdvice = .none
    /// Everything this screen still needs answered, from both owners, in one list.
    public private(set) var questions: [AnswerableQuestion] = []

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore, code: ReliefCode) {
        self.context = context
        self.store = store
        self.code = code
    }

    /// The Year of Assessment this detail screen is showing, for the "not part of the
    /// YYYY rulebook" empty state. `context` stays `private`: this computed property is
    /// declared on the same type, where `private` is already visible.
    public var yearOfAssessment: Int { context.year }

    /// Whether the engine grants this relief from household facts rather than from
    /// anything the user logs.
    ///
    /// SELF_AND_DEPENDENTS is the clearest case: RM 9,000 to every resident individual,
    /// no claim required. The screen said "Fully claimed. You have used all of this relief
    /// for this year" above "Nothing logged for this relief yet" — two sentences that
    /// cannot both be about the same thing, and neither describing what happened.
    public var isAutomatic: Bool {
        context.rule(for: code)?.automatic ?? false
    }

    /// Whether this relief's ceiling is counted once per dependant.
    ///
    /// Such a relief has a cap of zero until a dependant is recorded, and zero headroom
    /// with it — which the screen used to read as "fully claimed". Knowing the cap's shape
    /// is what lets it say the true thing instead: there is nobody to claim for yet.
    public var isPerDependent: Bool {
        guard case .perDependent = context.rule(for: code)?.cap else { return false }
        return true
    }

    /// Whether logging an entry against this relief would do anything.
    ///
    /// An `automatic` relief is granted in full from household facts and the evaluator
    /// discards any logged amount without a trace — `EntryEditorViewModel.validationError`
    /// already refuses one, so offering the button would walk the user into that refusal.
    /// An ineligible relief is the same story for a different reason.
    ///
    /// `.needsInfo` is excluded too. Logging against a relief whose eligibility is unknown
    /// is not wrong, but it is not the next step: the answer is, and the "To claim this"
    /// section above says so.
    public var canLogEntries: Bool {
        guard let assessment else { return false }
        guard context.rule(for: code)?.automatic != true else { return false }
        if case .eligible = assessment.eligibility { return true }
        return false
    }

    public func refresh() async {
        guard let found = context.result?.assessment(for: code) else {
            assessment = nil
            entries = []
            subLimits = []
            requirements = []
            sourceURL = nil
            notes = nil
            advice = .none
            questions = []
            return
        }

        assessment = found
        subLimits = found.children
        requirements = found.requirements
        sourceURL = found.sourceURL
        notes = found.notes

        // A sub-limit's entries belong to it, not to the parent, so the parent screen
        // lists only its own — the children are rendered as their own rows.
        let all = (try? await store.entryDrafts(forYear: context.year)) ?? []
        entries = all
            .filter { $0.code == code }
            .sorted { left, right in
                if left.spentOn != right.spentOn {
                    return (left.spentOn ?? .distantPast) > (right.spentOn ?? .distantPast)
                }
                return left.id.uuidString < right.id.uuidString
            }

        // After `entries`: what the user has already logged is half of what the advice
        // decides.
        advice = await contributionAdvice(for: found)
        questions = Self.merged(eligibility: found.eligibility, advice: advice)
    }

    /// Writes the offered figure as an ordinary relief entry.
    ///
    /// The row carries `suggestion.entryID`, a well-known id derived from the scheme and
    /// the year, and that makes acceptance idempotent: a second tap, a retry, or a racing
    /// tap on another device lands on the same row instead of inserting a second one the
    /// evaluator would sum. It also revives the row if the user had deleted it, because the
    /// ordinary write path fetches by id regardless of `deletedAt`.
    ///
    /// The well-known id does nothing else. Once the row exists it is an ordinary user
    /// entry: Relio never rewrites its amount when the income timeline changes, never soft
    /// deletes it, and never reconciles it.
    ///
    /// Do not add a background reconciler. It would be a second writer of a CloudKit-synced
    /// row under newest-write-wins, which is how a stale device resurrects a figure the
    /// user has already replaced — the exact double-count this whole design exists to
    /// prevent.
    ///
    /// - Returns: whether the entry was written.
    @discardableResult
    public func acceptSuggestion() async -> Bool {
        guard case .offer(let suggestion) = advice else { return false }
        do {
            try await store.save(EntryDraft(id: suggestion.entryID,
                                            year: context.year,
                                            code: code,
                                            amount: suggestion.amount))
        } catch {
            return false
        }
        await context.reload()
        await refresh()
        return true
    }

    /// The contribution card for this screen, when this screen is a contribution screen.
    ///
    /// The scheme lookup comes first so that the great majority of relief screens, which
    /// are not contribution screens, never reach the store at all.
    private func contributionAdvice(for assessment: ReliefAssessment) async -> ContributionAdvice {
        guard let scheme = ContributionScheme.allCases.first(where: { $0.reliefCode == code }),
              let estimate = try? await store.contributionEstimate(scheme: scheme,
                                                                   year: context.year) else {
            return .none
        }
        return ContributionAdvice.advise(estimate: estimate,
                                         assessment: assessment,
                                         loggedEntries: entries)
    }

    /// Both owners' unanswered questions, the rulebook's first.
    ///
    /// The split behind them is real and stays real: `ProfileQuestion` is TaxKit's
    /// vocabulary of eligibility predicates and `ContributionQuestion` is TaxData's
    /// vocabulary of payroll facts, and neither module should learn the other's. It just
    /// stops here, because the screen has one list to render and one sheet to open.
    private static func merged(eligibility: Eligibility,
                               advice: ContributionAdvice) -> [AnswerableQuestion] {
        var questions: [AnswerableQuestion] = []
        if case .needsInfo(let profile) = eligibility {
            questions += profile.map(AnswerableQuestion.profile)
        }
        if case .answer(let contribution, _) = advice {
            questions += contribution.map(AnswerableQuestion.contribution)
        }
        return questions
    }
}
