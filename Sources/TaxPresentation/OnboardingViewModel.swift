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

    /// What the user earns a month, and when that started. Onboarding asks for these two
    /// because they are what a person knows on the day they install the app — an annual
    /// total is arithmetic they would have to do themselves, which is the problem the
    /// income timeline exists to remove.
    public var monthlySalary: Money?
    public var salaryStartedOn: Date?

    /// Public so the screen can keep a salary start date inside the year being
    /// onboarded. Today's date is not a safe default for it: the newest shipped rulebook
    /// is usually the *previous* year, so a picker defaulting to today would offer a
    /// date the derivation reads as "not this year yet" and quietly derive RM 0.
    public let year: Int

    private let store: TaxStore

    /// Fixed for the life of this view model, so a retry after a failed write updates the
    /// same row rather than inserting a second "Main job". `finish()` can now be tapped
    /// again — a fresh `UUID()` per attempt would leave one orphaned source per failure,
    /// and there is no dedupe for `IncomeSource`.
    private let mainJobSourceID = UUID()

    public init(store: TaxStore, year: Int) {
        self.store = store
        self.year = year
    }

    public var isLastStep: Bool { step == OnboardingStep.allCases.last }

    public func advance() {
        guard let next = OnboardingStep(rawValue: step.rawValue + 1) else { return }
        step = next
    }

    /// What `finish()`/`skip()` actually managed to do.
    ///
    /// Onboarding used to mark itself complete regardless. A failed salary write then left
    /// the user on Home believing they had entered one, with no tax figures, no
    /// explanation, and no way back — onboarding never runs a second time. Every other
    /// write path in the app reports failure; this was the last one that swallowed, and
    /// the one the user can least recover from.
    public enum Outcome: Hashable, Sendable {
        case finished
        /// The facts were saved, the salary was not, and onboarding is deliberately still
        /// open so the user can try again rather than losing it silently.
        case incomeNotSaved
    }

    public func skip() async {
        facts = YearFacts()
        incomeEnabled = false
        // Same reason `facts` is reset: skipping discards answers already typed rather
        // than quietly keeping them. `complete()` gates the salary on `incomeEnabled`
        // too, so this is belt and braces — but it means a later reader of these
        // properties cannot find an answer the user chose not to give.
        monthlySalary = nil
        salaryStartedOn = nil
        // Skipping asks for no income at all, so there is nothing that can fail to save
        // and nothing to keep the screen open for. Unchanged behaviour.
        await complete()
    }

    @discardableResult
    public func finish() async -> Outcome {
        await complete()
    }

    @discardableResult
    private func complete() async -> Outcome {
        var toSave = facts
        if !incomeEnabled {
            // With the module off, onboarding must leave the year's income exactly as it
            // found it: no override written, and — below — no source or rate written
            // either. A figure typed into a step the user then turned off is not an
            // answer they gave.
            //
            // Before the income timeline this line guaranteed the engine saw no income at
            // all, because the year's own field *was* the income. It now clears only the
            // override, and a timeline would still feed the engine underneath it. That is
            // still sufficient here, and only here: onboarding runs once, before the user
            // has had any way to create a source, so there is no timeline to feed
            // anything. Any other caller of this pattern would need to say so explicitly.
            toSave.grossIncomeOverride = nil
        }

        try? await store.saveYearFacts(toSave, for: year)

        var outcome = Outcome.finished

        if incomeEnabled, let monthlySalary, monthlySalary > .zero {
            do {
                let sourceID = try await store.save(
                    IncomeSourceDraft(id: mainJobSourceID, name: "Main job"))
                var rate = IncomeRecordDraft(sourceID: sourceID)
                rate.shape = .recurring
                rate.amount = monthlySalary
                // Default to the start of the year being onboarded rather than today: a
                // salary the user has had all year should count for the whole year.
                rate.effectiveFrom = salaryStartedOn ?? IncomeCalendar.startOfYear(year)
                try await store.save(rate)
            } catch {
                // No fabricated source id. `TaxStore.save(_: IncomeRecordDraft)` rejects a
                // record whose source does not exist, so inventing one here would throw
                // the user's whole onboarding salary away without a trace; and if it ever
                // stopped rejecting it, the rate would save against nothing and be
                // invisible to every read. Writing neither is the only honest outcome.
                //
                // And it is reported, so the screen can stay open and say so. Marking
                // onboarding complete here would strand the user: they asked for a salary,
                // Relio kept none of it, and the one screen that asks for it never opens
                // again.
                outcome = .incomeNotSaved
            }
        }

        guard outcome == .finished else { return outcome }

        if var preferences = try? await store.preferences() {
            preferences.hasCompletedOnboarding = true
            preferences.incomeModuleEnabled = incomeEnabled
            preferences.lastViewedYear = year
            try? await store.savePreferences(preferences)
        }
        return outcome
    }
}
