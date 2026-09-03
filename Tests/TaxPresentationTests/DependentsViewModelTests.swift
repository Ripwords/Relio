import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

/// Nothing in the app could add a dependant. `EntryEditorView` has always had a "Which
/// person" picker reading the store, and no screen ever wrote to it — so the picker was
/// permanently empty, the five child reliefs were unclaimable, and
/// `ProfileQuestion.dependentDetails` had nowhere to be answered.
@Suite("Dependants") @MainActor struct DependentsViewModelTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func model(_ store: TaxStore, year: Int = 2025) async -> DependentsViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        let model = DependentsViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    /// A dependant is an input to eligibility, not just a row in a list. Adding a child
    /// under 18 is what makes CHILD_UNDER_18 claimable at all.
    ///
    /// The first cut of this model held only a store and a year, so it could refresh its
    /// own list and nothing else. The user added a child, watched the list grow, and saw
    /// every child relief stay exactly as unavailable as it had been — until the app was
    /// relaunched.
    @Test("adding a child re-evaluates the year, not just this list")
    func savingReEvaluatesTheYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = DependentsViewModel(context: context, store: store)
        await model.refresh()

        func childReliefIsClaimable() -> Bool {
            guard let child = context.result?.assessment(for: .childUnder18) else { return false }
            if case .eligible = child.eligibility { return child.cap > .zero }
            return false
        }
        #expect(childReliefIsClaimable() == false)

        _ = await model.save(DependentDraft(name: "Zara",
                                            kind: .child,
                                            dateOfBirth: Self.date(2018, 5, 2),
                                            isDisabled: false,
                                            yearStatuses: [DependentYearStatus(year: 2025)]))
        #expect(childReliefIsClaimable() == true)
    }

    @Test("a saved dependant comes back with the year's status attached")
    func savingRoundTrips() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.dependents.isEmpty)

        let child = DependentDraft(name: "Aisyah",
                                   kind: .child,
                                   dateOfBirth: Self.date(2010, 3, 14),
                                   isDisabled: false,
                                   yearStatuses: [DependentYearStatus(year: 2025,
                                                                      educationLevel: .preTertiary,
                                                                      claimPercentage: 50,
                                                                      isFullTime: true)])
        #expect(await model.save(child) == true)

        let row = try #require(model.dependents.first)
        #expect(row.name == "Aisyah")
        #expect(row.status?.claimPercentage == 50)
        #expect(row.status?.educationLevel == .preTertiary)
    }

    /// Age at the end of the year being viewed, not age today. Every child relief is
    /// decided on the former, and a child who turned 18 in 2026 was still 17 for the whole
    /// of YA2025 — claiming them there is correct and claiming them now is not.
    @Test("age is taken at the end of the year being viewed")
    func ageIsForTheYearNotToday() async throws {
        let store = try await PresentationFixture.store()
        _ = try await store.save(DependentDraft(name: "Danial",
                                                kind: .child,
                                                dateOfBirth: Self.date(2008, 1, 1)))
        let inTwentyFive = await Self.model(store, year: 2025)
        #expect(inTwentyFive.dependents.first?.age == 17)

        let inTwentyThree = await Self.model(store, year: 2023)
        #expect(inTwentyThree.dependents.first?.age == 15)
    }

    /// A dependant with no date of birth is legitimate — the user may not have it to hand
    /// — and must not be rendered as age zero, which the age reliefs would read as a
    /// newborn.
    @Test("a dependant with no date of birth has no age, not an age of zero")
    func missingBirthDateHasNoAge() async throws {
        let store = try await PresentationFixture.store()
        _ = try await store.save(DependentDraft(name: "Unknown", kind: .child))
        let model = await Self.model(store)
        #expect(model.dependents.first?.age == nil)
    }

    @Test("children come before parents, and the order is stable")
    func orderIsStable() async throws {
        let store = try await PresentationFixture.store()
        _ = try await store.save(DependentDraft(name: "Mum", kind: .parent))
        _ = try await store.save(DependentDraft(name: "Zara", kind: .child))
        _ = try await store.save(DependentDraft(name: "Aisyah", kind: .child))
        _ = try await store.save(DependentDraft(name: "Nenek", kind: .grandparent))

        let model = await Self.model(store)
        #expect(model.dependents.map(\.name) == ["Aisyah", "Zara", "Mum", "Nenek"])

        await model.refresh()
        #expect(model.dependents.map(\.name) == ["Aisyah", "Zara", "Mum", "Nenek"])
    }

    /// Spec §11.6. Deleting a dependant takes the child reliefs claimed against them with
    /// it, which is a large and silent consequence for one tap.
    @Test("deleting a dependant offers them back by name")
    func deletingIsUndoable() async throws {
        let store = try await PresentationFixture.store()
        let id = try await store.save(DependentDraft(name: "Aisyah", kind: .child))
        let model = await Self.model(store)

        #expect(await model.delete(id: id) == true)
        #expect(model.dependents.isEmpty)
        #expect(model.lastDeleted?.name == "Aisyah")

        await model.undoDelete()
        #expect(model.dependents.map(\.name) == ["Aisyah"])
        #expect(model.lastDeleted == nil)
    }

    @Test("dismissing the toast leaves the delete standing")
    func clearingUndoDoesNotRestore() async throws {
        let store = try await PresentationFixture.store()
        let id = try await store.save(DependentDraft(name: "Aisyah", kind: .child))
        let model = await Self.model(store)
        await model.delete(id: id)
        model.clearUndo()
        #expect(model.lastDeleted == nil)
        #expect(model.dependents.isEmpty)
    }
}
