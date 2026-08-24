import Foundation
import Observation
import TaxKit
import TaxData

public enum LoadStatus: Hashable, Sendable {
    case idle
    case loading
    case ready
    /// The year has no shipped rulebook. The user's entries still exist.
    case unavailable(String)
}

/// The one evaluation every screen reads.
///
/// `evaluate` walks the whole rulebook, and Home, Reliefs and the detail screens all need
/// its output. Three screens each holding their own copy would mean three evaluations per
/// year change and three chances to disagree about the same number — which is precisely
/// the failure a tax app cannot have.
///
/// `@Observable` and `@MainActor`: this is view state. All the work happens inside the
/// `TaxStore` actor and only the finished value comes back here.
@MainActor
@Observable
public final class YearContext {

    public private(set) var year: Int
    public private(set) var availableYears: [Int]
    public private(set) var result: EvaluationResult?
    public private(set) var status: LoadStatus = .idle
    /// The decoded rulebook behind `result`, cached so `rule(for:)` never re-decodes.
    /// `BundledRuleSetLoader` has no cache of its own, and a synchronous file read plus
    /// JSON decode per code — the editor asks once per offerable relief — would blow the
    /// spec's per-frame budget on the MainActor. Reassigned every `load()`, which is
    /// exactly when the year (and so the rulebook) can change, so there is no separate
    /// invalidation path to keep in sync.
    public private(set) var ruleSet: RuleSet?

    private let store: TaxStore
    private let loader: any RuleSetLoading

    public init(store: TaxStore, loader: any RuleSetLoading, year: Int) {
        self.store = store
        self.loader = loader
        self.year = year
        self.availableYears = loader.availableYears
    }

    public func load() async {
        // The year this load is *for*, captured before any suspension.
        //
        // Two loads can be in flight at once — the switcher is a segmented control, and
        // a year with no shipped rulebook fails synchronously while a year with one
        // suspends in `store.project`, so the second switch can finish before the first
        // resumes. Without this guard the older load then writes its evaluation into the
        // single object every screen reads, and the app shows one year's figures under
        // another year's label. Every assignment below is gated on the request still
        // being the current one; a superseded load exits having changed nothing.
        let requested = year
        status = .loading
        do {
            let ruleSet = try loader.ruleSet(for: requested)
            let projected = try await store.project(year: requested)
            guard requested == year else { return }
            self.ruleSet = ruleSet
            result = evaluate(ruleSet: ruleSet,
                              year: projected.snapshot,
                              entries: projected.entries)
            status = .ready
        } catch let error as RuleSetLoadingError {
            guard requested == year else { return }
            self.ruleSet = nil
            result = nil
            switch error {
            case .noRulesForYear:
                // Not an error state. Every January until the Budget ships, the current
                // year has no rulebook, and the user's entries for it still exist and
                // still matter.
                status = .unavailable("Rules for \(year) aren't available yet.")
            case .malformed:
                // A genuine failure: a rulebook shipped inside the app failed to decode.
                // The screen shape stays the same as the calm "not shipped yet" state —
                // there is still nothing to show — but the message must not tell the
                // user this is a normal wait, or they will sit waiting for a Budget that
                // already happened while every figure silently shows nothing.
                status = .unavailable("The rulebook for \(year) could not be read.")
            }
        } catch {
            guard requested == year else { return }
            self.ruleSet = nil
            result = nil
            status = .unavailable("Could not load \(year): \(error.localizedDescription)")
        }
    }

    public func reload() async {
        await load()
    }

    /// The rulebook entry behind a code, for the few decisions the evaluation result
    /// does not carry — `automatic` chief among them. Reads the cache `load()` already
    /// populated rather than asking the loader again.
    public func rule(for code: ReliefCode) -> ReliefRule? {
        ruleSet?.relief(for: code)
    }

    public func switchYear(to newYear: Int) async {
        // A no-op switch to the year already showing must not churn `updatedAt` on the
        // `UserPreferences` singleton — the same synced row the reconciliation sweep and
        // CloudKit's newest-write-wins both key off — for a call that changed nothing.
        // Gated on `.ready`, not just the year matching, so a genuine retry after a
        // failed or unavailable load still reloads.
        guard newYear != year || status != .ready else { return }
        year = newYear
        await load()
        // Same reason as the guard in `load()`: a switch that has been superseded must
        // not write its year back as the one to resume on next launch.
        guard newYear == year else { return }
        await rememberYear(newYear)
    }

    /// Launch resumes where the user left off. A failure here is not worth surfacing —
    /// the cost is opening on the wrong year once.
    private func rememberYear(_ newYear: Int) async {
        do {
            var preferences = try await store.preferences()
            preferences.lastViewedYear = newYear
            try await store.savePreferences(preferences)
        } catch {
            return
        }
    }
}
