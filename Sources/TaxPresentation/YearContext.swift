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

    private let store: TaxStore
    private let loader: any RuleSetLoading

    public init(store: TaxStore, loader: any RuleSetLoading, year: Int) {
        self.store = store
        self.loader = loader
        self.year = year
        self.availableYears = loader.availableYears
    }

    public func load() async {
        status = .loading
        do {
            let ruleSet = try loader.ruleSet(for: year)
            let projected = try await store.project(year: year)
            result = evaluate(ruleSet: ruleSet,
                              year: projected.snapshot,
                              entries: projected.entries)
            status = .ready
        } catch is RuleSetLoadingError {
            // Not an error state. Every January until the Budget ships, the current year
            // has no rulebook, and the user's entries for it still exist and still matter.
            result = nil
            status = .unavailable("Rules for \(year) aren't available yet.")
        } catch {
            result = nil
            status = .unavailable("Could not load \(year): \(error.localizedDescription)")
        }
    }

    public func reload() async {
        await load()
    }

    public func switchYear(to newYear: Int) async {
        year = newYear
        await load()
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
