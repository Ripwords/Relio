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

    /// Settings edits the same eight facts, but as a profile rather than a task. Someone
    /// who owns no property can never answer "what did your first home cost?", and gating
    /// Save on a complete set there would lock them out of changing anything else.
    @Test("Settings can save a partly answered profile")
    func settingsDoesNotRequireEveryAnswer() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = ProfileQuestionsViewModel(context: context,
                                              store: store,
                                              questions: [.maritalStatus, .propertyPrice],
                                              requiresEveryAnswer: false)
        await model.load()
        #expect(model.canSave == true)

        model.maritalStatus = .single
        await model.save()
        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.maritalStatus == .single)
        #expect(facts.propertyPrice == nil)
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
        // Through the text field, which is the path the user takes.
        model.propertyPriceText = "450000"
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

/// The bug this suite exists to prevent recurring.
///
/// `save()` writes every asked question's current value, nil included. A screen that
/// forgot to `load()` first would write nil over answers the user had already given —
/// and opened from Settings, where all eight questions are asked, that is every household
/// fact they own, on a Save that looks like it is confirming what is on screen.
///
/// It shipped exactly that way: ProfileQuestionsSheet had no `.task`, so it opened blank
/// against a married profile and Save would have blanked it.
@Suite("Profile questions: save is gated on a load")
@MainActor
struct ProfileQuestionsLoadGuardTests {

    @Test("saving without loading first refuses instead of blanking the year")
    func saveWithoutLoadRefuses() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.maritalStatus = .married
        existing.spouseHasIncome = false
        existing.employmentType = .privateSector
        try await store.saveYearFacts(existing, for: 2025)

        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = ProfileQuestionsViewModel(context: context,
                                              store: store,
                                              questions: ProfileQuestion.allCases,
                                              requiresEveryAnswer: false)
        // Deliberately no load().
        #expect(model.hasLoaded == false)
        await model.save()

        #expect(model.saveError != nil)
        let after = try await store.yearFacts(for: 2025)
        #expect(after.maritalStatus == .married)
        #expect(after.spouseHasIncome == false)
        #expect(after.employmentType == .privateSector)
    }

    @Test("loading first shows the answers already given, and saving keeps them")
    func loadingShowsExistingAnswers() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.maritalStatus = .married
        existing.assessmentType = .separate
        try await store.saveYearFacts(existing, for: 2025)

        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = ProfileQuestionsViewModel(context: context,
                                              store: store,
                                              questions: ProfileQuestion.allCases,
                                              requiresEveryAnswer: false)
        await model.load()
        #expect(model.hasLoaded == true)
        #expect(model.maritalStatus == .married)
        #expect(model.assessmentType == .separate)

        await model.save()
        let after = try await store.yearFacts(for: 2025)
        #expect(after.maritalStatus == .married)
        #expect(after.assessmentType == .separate)
    }
}

/// The property price is the only typed answer on the sheet, and typing has a shape the
/// tick-box answers do not: half-typed text is not a `Money`.
@Suite("Profile questions: the typed answer")
@MainActor
struct ProfileQuestionsPriceTests {

    static func model(_ store: TaxStore) async -> ProfileQuestionsViewModel {
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = ProfileQuestionsViewModel(context: context,
                                              store: store,
                                              questions: [.propertyPrice],
                                              requiresEveryAnswer: false)
        await model.load()
        return model
    }

    /// Held as `@State` in the sheet, a price already in the store populated the model and
    /// left the field looking empty — the user was shown a blank box for an answer they
    /// had already given, and only a fresh figure could get past it.
    @Test("a price already saved comes back in the field, not just in the model")
    func loadedPriceAppearsInTheField() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.propertyPrice = Money(ringgit: 450_000)
        try await store.saveYearFacts(existing, for: 2025)

        let model = await Self.model(store)
        #expect(model.propertyPrice == Money(ringgit: 450_000))
        #expect(!model.propertyPriceText.isEmpty)
        #expect(MoneyParsing.money(from: model.propertyPriceText) == Money(ringgit: 450_000))
    }

    @Test("clearing the field clears the answer rather than keeping the old one")
    func clearingTheFieldClearsTheAnswer() async throws {
        let store = try await PresentationFixture.store()
        var existing = YearFacts()
        existing.propertyPrice = Money(ringgit: 450_000)
        try await store.saveYearFacts(existing, for: 2025)

        let model = await Self.model(store)
        model.propertyPriceText = ""
        #expect(model.propertyPrice == nil)

        await model.save()
        #expect(try await store.yearFacts(for: 2025).propertyPrice == nil)
    }

    @Test("half-typed text is not an answer yet")
    func partialTextIsNotAnAnswer() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        model.propertyPriceText = "abc"
        #expect(model.propertyPrice == nil)
        #expect(model.isAnswered(.propertyPrice) == false)
    }
}
