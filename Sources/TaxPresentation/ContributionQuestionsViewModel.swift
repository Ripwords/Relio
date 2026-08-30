import Foundation
import Observation
import TaxKit
import TaxData

/// The state behind the sheet that asks for the payroll facts a contribution floor is
/// blocked on.
///
/// Every string, every ordering and every write lives here rather than in the sheet:
/// `App/` sits outside `swift test`'s reach, and the write below is the one this feature
/// can get silently and expensively wrong.
@MainActor
@Observable
public final class ContributionQuestionsViewModel {

    public struct SourceQuestion: Identifiable, Hashable, Sendable {

        /// A row is identified by the pair, never by the source alone. Two rows can name
        /// the same source, one asking about EPF and one about SOCSO, so a bare source id
        /// is not unique among them, and a `ForEach` keyed on one would collapse the two
        /// rows and route both pickers at whichever survived.
        public struct ID: Hashable, Sendable {
            public let sourceID: UUID
            public let scheme: ContributionScheme
        }

        /// The whole draft, never just a name and an id.
        public var draft: IncomeSourceDraft
        public let scheme: ContributionScheme
        public let prompt: String
        public var answer: Bool?
        public var id: ID { ID(sourceID: draft.id, scheme: scheme) }
    }

    public private(set) var asksDateOfBirth: Bool
    public private(set) var asksNationality: Bool
    public var dateOfBirth: Date?
    public var nationality: NationalityClass?
    public var sourceQuestions: [SourceQuestion] = []
    public private(set) var saveError: String?

    private let store: TaxStore
    /// The `sourceDeducts` questions in the order they arrived, held until `load()` can
    /// resolve each id to the draft the row has to carry.
    private let pendingSources: [(scheme: ContributionScheme, sourceID: UUID)]

    public init(store: TaxStore, questions: [AnswerableQuestion]) {
        self.store = store

        var asksDateOfBirth = false
        var asksNationality = false
        var pendingSources: [(scheme: ContributionScheme, sourceID: UUID)] = []

        for question in questions {
            switch question {
            // `ReliefDetailView` already lists profile questions in its "To claim this"
            // section and nothing in this app answers them interactively yet.
            case .profile:
                break
            case .contribution(let contribution):
                switch contribution {
                case .dateOfBirth: asksDateOfBirth = true
                case .nationality: asksNationality = true
                case .sourceDeducts(let scheme, let sourceID):
                    pendingSources.append((scheme, sourceID))
                }
            }
        }

        self.asksDateOfBirth = asksDateOfBirth
        self.asksNationality = asksNationality
        self.pendingSources = pendingSources
    }

    /// Whether every question this sheet put to the user has an answer.
    ///
    /// The sheet's Save button hangs off this. Without it the sheet would have to invent a
    /// default for a question the user never touched, and `save()` deliberately refuses to
    /// do that: an untouched row writes nothing, so a half-answered save looks to the user
    /// like it landed and leaves the screen still asking.
    /// Whether Save has anything to write.
    ///
    /// `isComplete` is vacuously true when this sheet asks nothing, which happens if every
    /// source it was going to ask about has gone by the time `load()` runs. Saving then
    /// writes nothing, reports success and dismisses onto a card that still says the same
    /// thing, so the button has to be dead rather than merely useless.
    public var canSave: Bool { asksSomething && isComplete }

    private var asksSomething: Bool {
        asksDateOfBirth || asksNationality || !sourceQuestions.isEmpty
    }

    public var isComplete: Bool {
        if asksDateOfBirth, dateOfBirth == nil { return false }
        if asksNationality, nationality == nil { return false }
        // `sourceQuestions` holds only the rows this sheet is asking about, so every one
        // of them counts.
        return sourceQuestions.allSatisfy { $0.answer != nil }
    }

    public func load() async {
        let drafts = (try? await store.incomeSourceDrafts()) ?? []
        var byID: [UUID: IncomeSourceDraft] = [:]
        for draft in drafts { byID[draft.id] = draft }

        sourceQuestions = pendingSources.compactMap { pending in
            guard let draft = byID[pending.sourceID] else { return nil }
            // The slot takes a proper name, as in "Does Acme Sdn Bhd deduct EPF from
            // your pay?". "this job" is not one, so it takes no capital and the sentence
            // reads as ordinary English.
            let name = draft.name.isEmpty ? "this job" : draft.name
            let question = ContributionQuestion.sourceDeducts(scheme: pending.scheme,
                                                              sourceID: pending.sourceID)
            return SourceQuestion(draft: draft,
                                  scheme: pending.scheme,
                                  prompt: ReliefCopy.prompt(for: question, sourceNamed: name),
                                  answer: nil)
        }

        // Seeds only what is still unanswered. This runs from the sheet's `.task`, which
        // is after the first render, so a tap can land while the store read is in flight;
        // assigning unconditionally would throw that answer away, which is the one thing
        // this sheet is built not to do.
        let profile = (try? await store.contributorProfile()) ?? ContributorProfile()
        if dateOfBirth == nil { dateOfBirth = profile.dateOfBirth }
        if nationality == nil { nationality = profile.nationality }
    }

    /// Writes every answer this sheet collected, and reports whether all of them landed.
    ///
    /// No early return on the first failure. The writes are independent, and abandoning
    /// the rest would throw away answers the user has already given over a failure that
    /// has nothing to do with them.
    ///
    /// - Returns: whether every write it attempted succeeded.
    @discardableResult
    public func save() async -> Bool {
        saveError = nil
        var everythingLanded = true

        if asksDateOfBirth || asksNationality {
            do {
                // Read, modify, write. `saveContributorProfile` writes both fields, so
                // sending a profile built from this sheet alone would blank the field this
                // sheet did not ask about, and an answer already given would silently
                // revert to unasked.
                let stored = try await store.contributorProfile()
                var profile = stored
                if asksDateOfBirth, let dateOfBirth { profile.dateOfBirth = dateOfBirth }
                if asksNationality, let nationality { profile.nationality = nationality }
                // A write that changes nothing still re-stamps the CloudKit-synced
                // preferences row, and under newest-write-wins that would let a sheet the
                // user closed without changing anything outrank a genuine edit made on
                // another device. The same discipline `softDeleteEntry` keeps.
                if profile != stored { try await store.saveContributorProfile(profile) }
            } catch {
                everythingLanded = false
            }
        }

        for draft in foldedSourceAnswers() {
            do {
                try await store.save(draft)
            } catch {
                everythingLanded = false
            }
        }

        if !everythingLanded {
            // Not "Nothing was changed". `save()` performs several independent store
            // writes, so a partial success is a real outcome, and claiming otherwise
            // would be a lie the user cannot check.
            saveError = "Relio could not save all of your answers. "
                + "The ones that saved are kept, so it is safe to try again."
        }
        return everythingLanded
    }

    /// One draft per source, carrying every answer given about it, in first-seen order.
    ///
    /// Two rows can name the same source, one asking about EPF and one about SOCSO, and
    /// both hold the draft as it was at `load()` time. Writing them one at a time would
    /// have the second write carry a stale flag for the first scheme and undo the answer
    /// the first write had just saved.
    ///
    /// The whole draft travels, never a fresh one built from the name and the id:
    /// `TaxStore.save(_ draft: IncomeSourceDraft)` overwrites every field the draft
    /// carries, so a partial draft silently nulls the fields this sheet never shows.
    private func foldedSourceAnswers() -> [IncomeSourceDraft] {
        var byID: [UUID: IncomeSourceDraft] = [:]
        var order: [UUID] = []

        for question in sourceQuestions {
            // A row nobody touched is left alone: "not answered in this sheet" is not
            // "confirmed no deductions".
            guard let answer = question.answer else { continue }
            let id = question.draft.id
            if byID[id] == nil { order.append(id) }
            var draft = byID[id] ?? question.draft
            switch question.scheme {
            case .employeesProvidentFund: draft.deductsEPF = answer
            case .socialSecurity: draft.deductsSOCSO = answer
            }
            byID[id] = draft
        }

        return order.compactMap { byID[$0] }
    }
}
