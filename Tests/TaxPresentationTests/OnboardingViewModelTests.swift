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
        model.facts.grossIncome = Money(ringgit: 128_000)
        await model.finish()

        let facts = try await store.yearFacts(for: 2025)
        #expect(facts.maritalStatus == .married)
        #expect(facts.grossIncome == Money(ringgit: 128_000))

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
        #expect(facts.grossIncome == nil)
        #expect(try await store.preferences().hasCompletedOnboarding)
        #expect(try await store.preferences().incomeModuleEnabled == false)
    }

    @Test("income left off is not written even if a figure was typed")
    func incomeToggleGates() async throws {
        let store = try await PresentationFixture.store()
        let model = OnboardingViewModel(store: store, year: 2025)
        model.facts.grossIncome = Money(ringgit: 128_000)
        model.incomeEnabled = false
        await model.finish()

        // Otherwise turning the module off in Settings would leave a stale salary driving
        // every tax figure in the app.
        #expect(try await store.yearFacts(for: 2025).grossIncome == nil)
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
}
