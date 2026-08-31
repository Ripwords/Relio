import Testing
import Foundation
import TaxKit
@testable import TaxData
@testable import TaxPresentation

@MainActor
private enum QuestionsFixture {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    /// A salaried job whose EPF floor clears the RM4,000 cap once the contributor is
    /// known, so the only thing standing between the screen and an offer is the two
    /// profile answers this sheet collects.
    static func seedSalariedJob(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncomeOverride = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)

        var job = IncomeSourceDraft(name: "Main job")
        job.deductsEPF = true
        let sourceID = try await store.save(job)

        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 5_000)
        rate.effectiveFrom = date(2024, 1, 1)
        _ = try await store.save(rate)
    }

    static func source(in store: TaxStore, id: UUID) async throws -> IncomeSourceDraft? {
        try await store.incomeSourceDrafts().first { $0.id == id }
    }
}

@Suite("Contribution questions") @MainActor struct ContributionQuestionsTests {

    /// The partial-draft regression, stated as a test.
    ///
    /// It would fail the moment someone reconstructed the source from just the name and
    /// the id it has on the row: `TaxStore.save(_ draft: IncomeSourceDraft)` overwrites
    /// every field the draft carries, so the fields this sheet never shows have to travel
    /// through it whole. The seeded source deliberately has a non-default value in all
    /// four of them, so each one has something to lose.
    @Test("answering one scheme leaves the source's other fields exactly as they were")
    func answeringOneSchemeKeepsTheWholeDraft() async throws {
        let store = try await PresentationFixture.store()
        var job = IncomeSourceDraft(name: "Borneo Trading Sdn Bhd")
        job.kind = .occasional
        job.deductsSOCSO = true
        job.endedOn = QuestionsFixture.date(2025, 9, 30)
        let sourceID = try await store.save(job)

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID))])
        await model.load()
        #expect(model.sourceQuestions.count == 1)
        #expect(model.sourceQuestions.first?.prompt.contains("Borneo Trading Sdn Bhd") == true)

        model.sourceQuestions[0].answer = true
        #expect(await model.save())

        let saved = try #require(await QuestionsFixture.source(in: store, id: sourceID))
        #expect(saved.deductsEPF == true)
        #expect(saved.deductsSOCSO == true)
        #expect(saved.name == "Borneo Trading Sdn Bhd")
        #expect(saved.kind == .occasional)
        #expect(saved.endedOn == QuestionsFixture.date(2025, 9, 30))
    }

    @Test("both schemes answered for one source leave both flags set, not just the last")
    func bothSchemesForOneSourceFoldIntoOneWrite() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Acme Sdn Bhd"))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID)),
                        .contribution(.sourceDeducts(scheme: .socialSecurity,
                                                     sourceID: sourceID))])
        await model.load()
        #expect(model.sourceQuestions.count == 2)

        // Different answers on purpose. Two `true`s would pass even if the second write
        // undid the first.
        model.sourceQuestions[0].answer = true
        model.sourceQuestions[1].answer = false
        #expect(await model.save())

        let saved = try #require(await QuestionsFixture.source(in: store, id: sourceID))
        #expect(saved.deductsEPF == true)
        #expect(saved.deductsSOCSO == false)
    }

    @Test("two schemes on one source are two distinct rows, not one")
    func rowsForOneSourceHaveDistinctIdentities() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Acme Sdn Bhd"))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID)),
                        .contribution(.sourceDeducts(scheme: .socialSecurity,
                                                     sourceID: sourceID))])
        await model.load()

        // The sheet renders these through `ForEach($model.sourceQuestions)`, which keys on
        // `id`. Were both rows to carry the source id alone, SwiftUI would collapse them
        // into one row and send both pickers' writes to whichever survived, so one of the
        // two answers would be silently lost before `save()` ever saw it.
        #expect(Set(model.sourceQuestions.map(\.id)).count == 2)
    }

    @Test("an answer given before the store read returns is not overwritten by it")
    func loadDoesNotClobberAnAnswerAlreadyGiven() async throws {
        let store = try await PresentationFixture.store()
        try await store.saveContributorProfile(
            ContributorProfile(dateOfBirth: QuestionsFixture.date(1988, 4, 2)))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.dateOfBirth), .contribution(.nationality)])

        // The sheet's `.task` runs after its first render, so this is a tap that lands
        // while `load()` is still in flight.
        let answered = QuestionsFixture.date(1995, 7, 20)
        model.dateOfBirth = answered
        model.nationality = .permanentResident
        await model.load()

        #expect(model.dateOfBirth == answered)
        #expect(model.nationality == .permanentResident)
    }

    @Test("a question left unanswered writes nothing")
    func unansweredRowsAreLeftAlone() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Acme Sdn Bhd"))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID))])
        await model.load()
        #expect(await model.save())

        let saved = try #require(await QuestionsFixture.source(in: store, id: sourceID))
        // Still "not asked", not "confirmed no deductions". Writing `false` here would
        // silence a question the user never saw an answer to.
        #expect(saved.deductsEPF == nil)
        #expect(saved.deductsSOCSO == nil)
    }

    @Test("answering only the nationality leaves a stored date of birth in place")
    func nationalityOnlyDoesNotBlankTheDateOfBirth() async throws {
        let store = try await PresentationFixture.store()
        let born = QuestionsFixture.date(1988, 4, 2)
        try await store.saveContributorProfile(ContributorProfile(dateOfBirth: born))

        let model = ContributionQuestionsViewModel(store: store,
                                                   questions: [.contribution(.nationality)])
        await model.load()
        #expect(model.asksNationality)
        #expect(model.asksDateOfBirth == false)
        // Seeded from the store, so an answer already given is not shown back as blank.
        #expect(model.dateOfBirth == born)

        model.nationality = .permanentResident
        #expect(await model.save())

        let profile = try await store.contributorProfile()
        #expect(profile.dateOfBirth == born)
        #expect(profile.nationality == .permanentResident)
    }

    @Test("a sheet closed without changing an answer does not re-stamp the profile")
    func savingAnUnchangedProfileWritesNothing() async throws {
        let store = try await PresentationFixture.store()
        try await store.saveContributorProfile(
            ContributorProfile(dateOfBirth: QuestionsFixture.date(1988, 4, 2),
                               nationality: .malaysianCitizen))
        let before = try #require(try await store.allPreferencesUpdatedAtForTesting().first)

        // Advance the clock so a re-stamp, if it happened, would be observable.
        await store.useClock { PresentationFixture.epoch.addingTimeInterval(3_600) }

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.dateOfBirth), .contribution(.nationality)])
        await model.load()
        #expect(await model.save())

        let after = try #require(try await store.allPreferencesUpdatedAtForTesting().first)
        #expect(after == before)
    }

    @Test("the sheet is complete only once every question it asked has an answer")
    func isCompleteTracksEveryAskedQuestion() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Acme Sdn Bhd"))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.dateOfBirth),
                        .contribution(.nationality),
                        .contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID))])
        await model.load()
        #expect(model.isComplete == false)

        model.dateOfBirth = QuestionsFixture.date(1990, 3, 12)
        #expect(model.isComplete == false)

        model.nationality = .malaysianCitizen
        // The source row is still outstanding, and it is the one `save()` would silently
        // skip rather than guess at.
        #expect(model.isComplete == false)

        model.sourceQuestions[0].answer = false
        #expect(model.isComplete)
    }

    /// The relief screen refreshes itself when this sheet is dismissed, and this is why
    /// that is enough on its own.
    ///
    /// Answering writes a contributor profile and income sources. The rulebook evaluates
    /// none of them, so `context.result` comes back equal and the screen's
    /// `.task(id: context.result)` never re-fires. Only the model's own `refresh()` re-reads
    /// the estimate. If that ever stopped being true the card would sit on screen still
    /// asking questions the user had just answered, and no other test would notice.
    @Test("the screen's own refresh is enough to clear the card, with no re-evaluation")
    func refreshAloneClearsTheCard() async throws {
        let store = try await PresentationFixture.store()
        try await QuestionsFixture.seedSalariedJob(store)
        let context = PresentationFixture.context(store)
        await context.load()

        let screen = ReliefDetailViewModel(context: context, store: store,
                                           code: .epfContribution)
        await screen.refresh()
        let evaluationBefore = context.result

        let sheet = ContributionQuestionsViewModel(store: store, questions: screen.questions)
        await sheet.load()
        sheet.dateOfBirth = QuestionsFixture.date(1990, 3, 12)
        sheet.nationality = .malaysianCitizen
        #expect(await sheet.save())

        // Deliberately no `context.reload()`: dismissing the sheet does not perform one.
        await screen.refresh()
        #expect(context.result == evaluationBefore)
        guard case .offer = screen.advice else {
            Issue.record("expected an offer once the answers landed, got \(screen.advice)")
            return
        }
    }

    @Test("answering the two profile questions stops the EPF screen asking")
    func answeringUnblocksTheEPFAdvice() async throws {
        let store = try await PresentationFixture.store()
        try await QuestionsFixture.seedSalariedJob(store)
        let context = PresentationFixture.context(store)
        await context.load()

        let screen = ReliefDetailViewModel(context: context, store: store,
                                           code: .epfContribution)
        await screen.refresh()
        guard case .answer = screen.advice else {
            Issue.record("expected the screen to be asking, got \(screen.advice)")
            return
        }

        let sheet = ContributionQuestionsViewModel(store: store, questions: screen.questions)
        await sheet.load()
        #expect(sheet.asksDateOfBirth)
        #expect(sheet.asksNationality)
        sheet.dateOfBirth = QuestionsFixture.date(1990, 3, 12)
        sheet.nationality = .malaysianCitizen
        #expect(await sheet.save())

        await context.reload()
        await screen.refresh()
        if case .answer = screen.advice {
            Issue.record("the answers were saved, so the screen must have stopped asking")
        }
    }
    /// A sheet with nothing left to ask must not offer to save nothing.
    ///
    /// `load()` drops rows whose source has gone since the estimate was taken, so a sheet
    /// built from one `sourceDeducts` question can arrive empty. `isComplete` is vacuously
    /// true there, and a Save hung off it would write nothing, report success and dismiss
    /// onto a card saying exactly what it said before.
    @Test("Save is dead when every question has gone, not merely useless")
    func nothingLeftToAskMeansNothingToSave() async throws {
        let store = try await PresentationFixture.store()
        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: UUID()))])
        await model.load()

        #expect(model.sourceQuestions.isEmpty)
        #expect(model.isComplete)
        #expect(model.canSave == false)
    }

    @Test("Save wakes up once the questions that were asked are answered")
    func canSaveFollowsTheAnswers() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Acme Sdn Bhd"))

        let model = ContributionQuestionsViewModel(
            store: store,
            questions: [.contribution(.dateOfBirth),
                        .contribution(.sourceDeducts(scheme: .employeesProvidentFund,
                                                     sourceID: sourceID))])
        await model.load()
        #expect(model.canSave == false)

        model.sourceQuestions[0].answer = true
        #expect(model.canSave == false)

        model.dateOfBirth = QuestionsFixture.date(1990, 3, 12)
        #expect(model.canSave)
    }

}
