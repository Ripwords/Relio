import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("OnboardingViewModel") @MainActor struct OnboardingViewModelTests {

    @Test("finishing writes the facts and marks onboarding done")
    func finishPersists() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)

        model.facts.maritalStatus = .married
        model.facts.spouseHasIncome = false
        model.incomeEnabled = true
        model.facts.grossIncomeOverride = Money(ringgit: 128_000)
        await model.finish()

        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.maritalStatus == .married)
        #expect(facts.grossIncomeOverride == Money(ringgit: 128_000))

        let preferences = try await store.preferences()
        #expect(preferences.hasCompletedOnboarding)
        #expect(preferences.incomeModuleEnabled)
    }

    @Test("skipping leaves every fact unanswered")
    func skipLeavesFactsNil() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        await model.skip()

        let facts = try await store.yearFacts(for: 2025)
        // nil, not a default. Spec §1: a receipt must be loggable in 30 seconds without
        // entering income, and a guessed marital status would silently change what the
        // engine grants.
        #expect(facts.maritalStatus == nil)
        #expect(facts.grossIncomeOverride == nil)
        #expect(try await store.preferences().hasCompletedOnboarding)
        #expect(try await store.preferences().incomeModuleEnabled == false)
    }

    @Test("income left off is not written even if a figure was typed")
    func incomeToggleGates() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.facts.grossIncomeOverride = Money(ringgit: 128_000)
        model.incomeEnabled = false
        await model.finish()

        // Otherwise turning the module off in Settings would leave a stale salary driving
        // every tax figure in the app.
        #expect(try await store.yearFacts(for: 2025).grossIncomeOverride == nil)
    }

    @Test("facts are written to the chosen year only")
    func factsAreScopedToTheYear() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.facts.maritalStatus = .married
        await model.finish()

        // Copying forward would assert facts about YA2023 the user never gave.
        #expect(try await store.yearFacts(for: 2023).maritalStatus == nil)
        #expect(try await store.yearFacts(for: 2025).maritalStatus == .married)
    }

    @Test("steps advance in order and stop at the end")
    func stepping() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        #expect(model.step == .welcome)
        model.advance()
        #expect(model.step == .household)
        model.advance()
        #expect(model.step == .income)
        #expect(model.isLastStep)
        model.advance()
        #expect(model.step == .income)
    }

    @Test("finishing with a salary creates a source and a rate")
    func salaryBecomesASource() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 8_000)
        await model.finish()

        let sources = try await store.incomeSourceDrafts()
        #expect(sources.count == 1)
        #expect(sources.first?.name == "Main job")
        // No start date given, so it runs from the start of the year being onboarded —
        // a salary the user has had all year counts for the whole year.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("a salary start date part-way through the year is honoured")
    func salaryStartDateIsUsed() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 9_000)
        var components = DateComponents()
        components.year = 2025; components.month = 7; components.day = 1; components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        model.salaryStartedOn = calendar.date(from: components)!
        await model.finish()

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 54_000))
    }

    @Test("income left off writes no source even if a salary was typed")
    func incomeToggleGatesTheSource() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.monthlySalary = Money(ringgit: 8_000)
        model.incomeEnabled = false
        await model.finish()
        // Otherwise turning the module off later leaves a stale salary quietly driving
        // every tax figure in the app.
        #expect(try await store.incomeSourceDrafts().isEmpty)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
    }

    @Test("skipping writes no income at all")
    func skipWritesNothing() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.incomeEnabled = true
        model.monthlySalary = Money(ringgit: 8_000)
        await model.skip()
        #expect(try await store.incomeSourceDrafts().isEmpty)
    }
}
