import Foundation
import Observation
import TaxKit
import TaxData

/// What the Compare screen shows.
///
/// TaxKit's `counterfactual` has been built and tested since the first plan and nothing
/// has ever called it. Spec §7 is explicit that the generic rule diff is not the feature
/// worth building — the personalised replay is: not "the cap went up" but "the cap going
/// up is worth RM 1,680 to you", computed by evaluating the user's own entries against
/// another year's rulebook.
@MainActor
@Observable
public final class CompareViewModel {

    /// Which year comes out ahead for this user. Named rather than left as a sign, so the
    /// view cannot get the direction backwards and tell someone a rule change cost them
    /// money when it made them money.
    public enum Direction: Hashable, Sendable {
        case betterOff
        case worseOff
        case noDifference
    }

    /// The year being viewed. Comparisons are read as "against" this one.
    public let baselineYear: Int
    public private(set) var comparisonYear: Int
    public private(set) var result: CounterfactualResult?

    /// Published rule changes that this user's own entries do not price.
    ///
    /// The counterfactual only reports reliefs whose *allowed* amount moved, and allowed
    /// is zero for a relief with no entries — so a user who claimed none of the reliefs a
    /// Budget touched sees "no difference for you" and learns nothing about what changed.
    /// That is honest but useless, and it is the common case: the YA2024→YA2025 changes
    /// are concentrated in disability and insurance reliefs most people never claim.
    ///
    /// The generic diff fills that in. Spec §7 is right that it is not the feature — the
    /// priced replay is — but shown *beside* the priced lines rather than instead of them,
    /// it answers the other half of the question the screen is opened with.
    public private(set) var ruleChanges: [ReliefDelta] = []
    public private(set) var status: LoadStatus = .idle

    private let store: TaxStore
    private let loader: any RuleSetLoading

    public init(store: TaxStore, loader: any RuleSetLoading, baselineYear: Int) {
        self.store = store
        self.loader = loader
        self.baselineYear = baselineYear
        // The nearest earlier shipped year: "what changed since last year" is the question
        // someone opens this screen with. Falls forward when the year being viewed is the
        // oldest one shipped.
        let others = loader.availableYears.filter { $0 != baselineYear }
        self.comparisonYear = others.last(where: { $0 < baselineYear })
            ?? others.last
            ?? baselineYear
    }

    /// Every shipped year except the one being viewed. Comparing a year with itself is an
    /// all-zero diff, which is not a screen — offering it in the picker only invites the
    /// tap.
    public var comparisonYears: [Int] {
        loader.availableYears.filter { $0 != baselineYear }
    }

    public func refresh() async {
        await compare(with: comparisonYear)
    }

    public func compare(with year: Int) async {
        comparisonYear = year
        status = .loading
        do {
            let baseline = try loader.ruleSet(for: baselineYear)
            let comparison = try loader.ruleSet(for: year)
            // The user's own entries, replayed. Both evaluations run over the same
            // projection — the point is that only the rulebook differs.
            let projected = try await store.project(year: baselineYear)
            let evaluated = counterfactual(entries: projected.entries,
                                           year: projected.snapshot,
                                           under: baseline,
                                           versus: comparison)
            result = evaluated
            // Earlier to later, always, so a change reads in the direction time runs
            // whichever year the user is standing in.
            let earlier = year < baselineYear ? comparison : baseline
            let later = year < baselineYear ? baseline : comparison
            // Anything the lines above already price is dropped: the same relief in both
            // sections, once with a figure and once without, reads as two changes.
            let priced = Set(evaluated.lines.map(\.code))
            ruleChanges = diff(from: earlier, to: later).filter { !priced.contains($0.code) }
            status = .ready
        } catch {
            result = nil
            ruleChanges = []
            status = .unavailable("Could not compare \(String(baselineYear)) with \(String(year)).")
        }
    }

    /// `totalReliefDifference` is `baseline - comparison`, so positive means the year being
    /// viewed allows more relief than the year compared against.
    public var direction: Direction {
        guard let result else { return .noDifference }
        if result.totalReliefDifference.sen > 0 { return .betterOff }
        if result.totalReliefDifference.sen < 0 { return .worseOff }
        return .noDifference
    }

    /// The figure the screen leads with, always positive — the direction is carried by
    /// `direction` and said in words, because a minus sign in front of a ringgit amount
    /// is read as "you owe this" at a glance.
    public var headlineAmount: Money {
        guard let result else { return .zero }
        return Money(sen: abs(result.totalReliefDifference.sen))
    }

    /// What that difference is worth in tax, when income is known. `nil` otherwise —
    /// the same rule the rest of the app follows rather than showing a zero.
    public var headlineTax: Money? {
        guard let difference = result?.taxDifference else { return nil }
        return Money(sen: abs(difference.sen))
    }
}
