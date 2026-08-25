import Foundation
import Observation
import TaxKit
import TaxData

public enum OnboardingStep: Int, CaseIterable, Hashable, Sendable {
    case welcome, household, income
}

/// Three skippable screens. Spec §11.
///
/// Nothing here is required. Skipping leaves every fact `nil`, which the engine renders
/// as prompts on Home — the user gets asked later, in context, by a screen that can say
/// what the answer is worth. That is strictly better than a wall of questions before the
/// app has shown it is useful.
@MainActor
@Observable
public final class OnboardingViewModel {

    public private(set) var step: OnboardingStep = .welcome
    public var facts = YearFacts()
    public var incomeEnabled = false

    private let store: TaxStore
    private let year: Int

    public init(store: TaxStore, year: Int) {
        self.store = store
        self.year = year
    }

    public var isLastStep: Bool { step == OnboardingStep.allCases.last }

    public func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    public func skip() async {
        facts = YearFacts()
        incomeEnabled = false
        await complete()
    }

    public func finish() async {
        await complete()
    }

    private func complete() async {
        var toSave = facts
        if !incomeEnabled {
            // Otherwise turning the module off later leaves a stale salary quietly
            // driving every tax figure in the app.
            toSave.grossIncome = nil
            toSave.epf = nil
            toSave.socso = nil
        }

        try? await store.saveYearFacts(toSave, for: year)

        if var preferences = try? await store.preferences() {
            preferences.hasCompletedOnboarding = true
            preferences.incomeModuleEnabled = incomeEnabled
            preferences.lastViewedYear = year
            try? await store.savePreferences(preferences)
        }
    }
}
