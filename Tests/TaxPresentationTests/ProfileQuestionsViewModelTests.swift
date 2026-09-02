import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

/// Home has always promised "answer one question to unlock RM 4,000" and had nowhere to
/// send the tap. This is the model behind the screen that answers it.
@Suite("Profile questions")
@MainActor
struct ProfileQuestionsViewModelTests {

    static func model(_ store: TaxStore,
                      _ questions: [ProfileQuestion],
                      year: Int = 2025) async -> ProfileQuestionsViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        let model = ProfileQuestionsViewModel(context: context, store: store, questions: questions)
        await model.load()
        return model
    }

    /// Two of the ten `ProfileQuestion` cases have no `YearFacts` slot to write to:
    /// `dependentDetails` is a property of a dependant row, and `lastClaimYear` has no
    /// storage anywhere in the app yet.
    ///
    /// They are filtered out rather than shown, and — this is the part that matters —
    /// `HomeViewModel` counts the same filtered list. A prompt offering to answer a
    /// question this screen cannot save would be a dead end one level further in: the
    /// user taps "answer 3 questions", answers the two that exist, and the prompt still
    /// reads "answer 1 question" for ever.
    @Test("a question with nowhere to write is not asked")
    func unanswerableQuestionsAreFiltered() {
        let asked = ProfileQuestionsViewModel.answerable(
            [.disabilityStatus, .dependentDetails, .lastClaimYear, .propertyPrice])
        #expect(asked == [.disabilityStatus, .propertyPrice])
    }

    @Test("nothing saves until every question asked has an answer")
    func saveIsGatedOnCompleteness() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store, [.disabilityStatus, .spouseDisabilityStatus])
        #expect(model.canSave == false)

        model.selfIsDisabled = false
        #expect(model.canSave == false, "one of two answered is not an answer")

        model.spouseIsDisabled = false
        #expect(model.canSave == true)
    }

    /// "No" is an answer and has to be storable as one. An engine that reads a `nil` as
    /// "not asked" and a `false` as "asked and refused" cannot tell them apart unless the
    /// screen is willing to write `false` — and a user who says they are not disabled
    /// should stop being asked.
    @Test("answering no is written, not treated as unanswered")
    func answeringNoIsPersisted() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store, [.disabilityStatus])
        model.selfIsDisabled = false
        await model.save()

        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.selfIsDisabled == false)
    }

    @Test("an answer reaches the store and the year's facts keep what was already there")
    func savingPreservesUnrelatedFacts() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.maritalStatus = .married
        existing.employmentType = .privateSector
        try await store.saveYearFacts(existing, for: 2025)

        let model = await Self.model(store, [.propertyPrice])
        model.propertyPrice = Money(ringgit: 450_000)
        await model.save()

        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.propertyPrice == Money(ringgit: 450_000))
        // The screen asks about one fact and must not blank the nine it did not ask about.
        #expect(facts.maritalStatus == .married)
        #expect(facts.employmentType == .privateSector)
    }

    /// The screen opens on what the store already holds, so a user reopening it sees
    /// their previous answer rather than an empty control that would overwrite it.
    @Test("existing answers are loaded, not blanked")
    func existingAnswersLoad() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.selfIsDisabled = true
        try await store.saveYearFacts(existing, for: 2025)

        let model = await Self.model(store, [.disabilityStatus])
        #expect(model.selfIsDisabled == true)
        #expect(model.canSave == true)
    }
}
