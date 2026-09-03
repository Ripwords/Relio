import Testing
import Foundation
@testable import TaxKit
import TaxData
@testable import TaxPresentation

/// The path a real person takes, across the view models that have to agree with each
/// other along it.
///
/// Every model here is tested on its own already. What those tests cannot catch is the
/// failure this session kept turning up: one screen changing the store and another still
/// showing what it copied out at launch. The Docs tab did exactly that after a save, and
/// only a walk through the app found it.
@Suite("A new user's first year") @MainActor struct NewUserJourneyTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    /// The three writes that are not entries, each of which changed the evaluation and
    /// each of which shipped without telling the screens that copy out of it.
    ///
    /// Adding a dependant, answering a household question, and undoing either one all
    /// move what Home should say. Every one of those was a separate bug; this asserts the
    /// behaviour they broke rather than the plumbing that fixes it, so a fourth instance
    /// fails here instead of shipping.
    @Test("a household change reaches the screens that copy out of the evaluation")
    func householdChangesReachEveryScreen() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()

        let home = HomeViewModel(context: context, store: store)
        await home.refresh()
        let questionsBefore = home.prompts.unansweredQuestions.count
        #expect(questionsBefore > 0)

        // Answering one of Home's own questions must reduce Home's own count, which is
        // only true if the evaluation reloaded and Home re-read it.
        let questions = ProfileQuestionsViewModel(context: context,
                                                  store: store,
                                                  questions: [.disabilityStatus],
                                                  requiresEveryAnswer: false)
        await questions.load()
        questions.selfIsDisabled = false
        await questions.save()
        await home.refresh()
        #expect(home.prompts.unansweredQuestions.count < questionsBefore)

        // Adding a child makes a relief claimable that was not, which Home ranks.
        let dependants = DependentsViewModel(context: context, store: store)
        await dependants.refresh()
        _ = await dependants.save(DependentDraft(name: "Zara",
                                                 kind: .child,
                                                 dateOfBirth: Self.date(2018, 5, 2),
                                                 isDisabled: false,
                                                 yearStatuses: [DependentYearStatus(year: 2025)]))
        await home.refresh()
        #expect(home.opportunities.contains { $0.code == .childUnder18 }
                || context.result?.assessment(for: .childUnder18)?.cap ?? .zero > .zero)
    }

    @Test("nothing logged, one child, one receipt — every screen keeps up")
    func theWholeWayThrough() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()

        let home = HomeViewModel(context: context, store: store)
        let documents = DocumentsViewModel(context: context, store: store)
        let reliefs = ReliefsListViewModel(context: context)
        let dependants = DependentsViewModel(context: context, store: store)

        // 1. Straight out of onboarding, having skipped it. Home must not lead with a
        //    headline summing every cap in the rulebook.
        await home.refresh()
        await documents.refresh()
        #expect(home.hasLoggedAnything == false)
        #expect(documents.outstanding.isEmpty)

        // 2. A child is added. This is the step that was impossible until dependants got
        //    a screen, and it is what the child reliefs are claimed against.
        await dependants.refresh()
        #expect(await dependants.save(DependentDraft(
            name: "Aisyah",
            kind: .child,
            dateOfBirth: Self.date(2012, 6, 1),
            isDisabled: false,
            yearStatuses: [DependentYearStatus(year: 2025,
                                               educationLevel: .preTertiary,
                                               claimPercentage: 100,
                                               isFullTime: true)])) == true)
        #expect(dependants.dependents.count == 1)
        #expect(dependants.dependents.first?.age == 13)

        // 3. A receipt is logged, the way the entry editor logs one.
        let editor = EntryEditorViewModel(context: context, store: store, editing: nil)
        await editor.load()
        editor.selectedCode = .lifestyle
        editor.amountText = "300"
        editor.vendor = "Kinokuniya"
        #expect(editor.validationError == nil)
        #expect(await editor.save() == true)

        // 4. Every screen has to reflect it. The editor reloads the shared evaluation, but
        //    Home and Documents copy out of it, so both have to be told to copy again —
        //    which is the bug this test exists for.
        await home.refresh()
        await documents.refresh()
        reliefs.refresh()

        #expect(home.hasLoggedAnything == true)
        #expect(home.prompts.claimsMissingDocuments == documents.outstanding.count)
        #expect(documents.outstanding.contains { $0.vendor == "Kinokuniya" })

        // The relief the receipt went to now shows the money against it, on the list and
        // in the entry editor's own view of the cap.
        let lifestyle = try #require(
            reliefs.sections.flatMap(\.rows).first { $0.code == .lifestyle })
        #expect(lifestyle.allowed == Money(ringgit: 300))

        // 5. Deleting it puts every screen back, and offers the entry back.
        //
        // Through a *fresh* editor opened against the saved entry, which is what the app
        // does: saving dismisses the sheet, and deleting means opening the entry again.
        // The editor that created it never learns its id — `editingID` is a `let` set at
        // init — so `canDelete` is false on it, correctly.
        let saved = try #require(try await store.entryDrafts(forYear: 2025)
            .first { $0.vendor == "Kinokuniya" })
        let reopened = EntryEditorViewModel(context: context, store: store, editing: saved.id)
        await reopened.load()
        #expect(reopened.canDelete == true)
        await reopened.delete()
        await home.refresh()
        await documents.refresh()
        #expect(home.hasLoggedAnything == false)
        #expect(!documents.outstanding.contains { $0.vendor == "Kinokuniya" })

        await reopened.undoDelete()
        await home.refresh()
        await documents.refresh()
        #expect(home.hasLoggedAnything == true)
        #expect(documents.outstanding.contains { $0.vendor == "Kinokuniya" })
    }
}
