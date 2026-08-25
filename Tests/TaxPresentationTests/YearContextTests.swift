import Testing
import Foundation
import Synchronization
import TaxKit
@testable import TaxData
@testable import TaxPresentation

/// Builders shared by every presentation suite.
enum PresentationFixture {

    static let epoch = Date(timeIntervalSince1970: 1_750_000_000)

    static func store() async throws -> TaxStore {
        let container = try TaxContainer.make(.inMemory)
        let store = TaxStore(modelContainer: container)
        await store.useClock { epoch }
        return store
    }

    /// A household with income, so `taxSaved` and `totalOpportunity` are non-nil.
    static func seedTypicalHousehold(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncomeOverride = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        try await store.saveYearFacts(facts, for: 2025)

        for (code, ringgit) in [("LIFESTYLE", Decimal(1_700)),
                                ("MEDICAL_CHECKUP", Decimal(400)),
                                ("SSPN", Decimal(1_000))] {
            var draft = EntryDraft(id: UUID(), year: 2025,
                                   code: ReliefCode(code), amount: Money(ringgit: ringgit))
            draft.vendor = code
            _ = try await store.save(draft)
        }
    }

    @MainActor
    static func context(_ store: TaxStore, year: Int = 2025) -> YearContext {
        YearContext(store: store, loader: BundledRuleSetLoader(), year: year)
    }
}

/// Throws a fixed `RuleSetLoadingError` regardless of the year asked for, so a test can
/// force `YearContext` down the `.malformed` or `.noRulesForYear` path on demand — the
/// `RuleSetLoading` protocol exists precisely so a fake can be substituted here.
private struct FailingRuleSetLoader: RuleSetLoading {
    let availableYears: [Int]
    let error: RuleSetLoadingError

    func ruleSet(for year: Int) throws -> RuleSet {
        throw error
    }
}

/// Counts calls to `ruleSet(for:)`, so a test can assert `YearContext.rule(for:)` reuses
/// a cached rule set rather than re-decoding the rulebook on every call. `Mutex` gives
/// thread-safe interior mutability without `@unchecked Sendable`.
private final class CallCountingLoader: RuleSetLoading, Sendable {
    let availableYears: [Int]
    private let inner: any RuleSetLoading
    private let count = Mutex<Int>(0)

    init(wrapping inner: any RuleSetLoading) {
        self.inner = inner
        self.availableYears = inner.availableYears
    }

    var callCount: Int { count.withLock { $0 } }

    func ruleSet(for year: Int) throws -> RuleSet {
        count.withLock { $0 += 1 }
        return try inner.ruleSet(for: year)
    }
}

/// Records `YearContext.status` at the instant the rulebook is asked for.
///
/// `load()` sets its status and then calls the loader with no suspension in between, so
/// this is the one deterministic window in which the transient `.loading` can be seen —
/// polling from the outside would race the completion.
@MainActor
final class LoadStatusProbe {
    var context: YearContext?
    var statusesAtRuleSetLookup: [LoadStatus] = []

    func record() {
        guard let context else { return }
        statusesAtRuleSetLookup.append(context.status)
    }
}

/// Calls back into a `LoadStatusProbe` from inside `ruleSet(for:)`.
///
/// `assumeIsolated` rather than a hop: `YearContext` is `@MainActor` and calls the loader
/// synchronously, so this genuinely is the main actor — and a hop would introduce exactly
/// the suspension the probe exists to avoid.
private struct ProbingRuleSetLoader: RuleSetLoading {
    let availableYears: [Int]
    let onLookup: @MainActor @Sendable () -> Void

    func ruleSet(for year: Int) throws -> RuleSet {
        MainActor.assumeIsolated { onLookup() }
        return try BundledRuleSetLoader().ruleSet(for: year)
    }
}

@Suite("YearContext") @MainActor struct YearContextTests {

    @Test("rule(for:) reuses the cached rule set rather than re-decoding on every call")
    func ruleForReusesCachedRuleSet() async throws {
        let store = try await PresentationFixture.store()
        let countingLoader = CallCountingLoader(wrapping: BundledRuleSetLoader())
        let context = YearContext(store: store, loader: countingLoader, year: 2025)
        await context.load()
        let countAfterLoad = countingLoader.callCount

        // The editor asks `rule(for:)` once per offerable relief plus once per existing
        // entry it loads — without a cache that is a synchronous file read and JSON
        // decode per call, on the MainActor, against a spec budget of no frame over 8ms.
        for code in ["LIFESTYLE", "SSPN", "MEDICAL_CHECKUP", "PARENTS_MEDICAL", "PARENTS_CHECKUP"] {
            _ = context.rule(for: ReliefCode(code))
        }

        #expect(countingLoader.callCount == countAfterLoad,
                "rule(for:) must reuse the cached rule set, not re-decode the rulebook per call")
    }

    @Test("loading evaluates the persisted year")
    func loadEvaluates() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        let context = PresentationFixture.context(store)
        #expect(context.status == .idle)
        await context.load()

        #expect(context.status == .ready)
        let result = try #require(context.result)
        #expect(result.yearOfAssessment == 2025)
        #expect(result.chargeableIncome != nil)
        #expect(result.assessment(for: ReliefCode("LIFESTYLE"))?.claimed == Money(ringgit: 1_700))
    }

    @Test("available years come from the loader")
    func availableYears() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        #expect(context.availableYears == [2023, 2024, 2025])
    }

    @Test("switching year re-evaluates against that year's rules")
    func switchingYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()

        await context.switchYear(to: 2023)
        #expect(context.year == 2023)
        #expect(context.status == .ready)
        // 2023 has no entries seeded, so nothing is claimed — but the automatic
        // individual relief still applies and the screen still has a number to show.
        #expect(context.result?.yearOfAssessment == 2023)
        #expect(context.result?.assessment(for: ReliefCode("LIFESTYLE"))?.claimed == Money.zero)
    }

    @Test("a year with no shipped rulebook is unavailable, not an error screen")
    func unshippedYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.switchYear(to: 2026)

        #expect(context.year == 2026)
        #expect(context.result == nil)
        guard case .unavailable(let message) = context.status else {
            Issue.record("expected .unavailable, got \(context.status)")
            return
        }
        // The user's entries are still there. A crash or a blank screen would imply
        // otherwise, and this is the state every January until the Budget ships.
        #expect(message.contains("2026"))
    }

    @Test("reloading picks up a write")
    func reloadSeesNewEntries() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let before = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)

        var addition = EntryDraft(id: UUID(), year: 2025,
                                  code: ReliefCode("SSPN"), amount: Money(ringgit: 500))
        addition.vendor = "Extra deposit"
        _ = try await store.save(addition)
        await context.reload()

        let after = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)
        #expect(after == before + Money(ringgit: 500))
    }

    @Test("a cold load announces itself as loading")
    func coldLoadAnnouncesLoading() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        let probe = LoadStatusProbe()
        let loader = ProbingRuleSetLoader(availableYears: [2025]) { probe.record() }
        let context = YearContext(store: store, loader: loader, year: 2025)
        probe.context = context

        #expect(context.status == .idle)
        await context.load()

        // Nothing was on screen, so the spinner every screen draws off `.loading` was the
        // honest thing to show.
        #expect(probe.statusesAtRuleSetLookup == [.loading])
        #expect(context.status == .ready)
    }

    @Test("a reload over an existing result never drops to loading")
    func reloadPreservesReady() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        let probe = LoadStatusProbe()
        let loader = ProbingRuleSetLoader(availableYears: [2025]) { probe.record() }
        let context = YearContext(store: store, loader: loader, year: 2025)
        probe.context = context
        await context.load()

        var addition = EntryDraft(id: UUID(), year: 2025,
                                  code: ReliefCode("SSPN"), amount: Money(ringgit: 500))
        addition.vendor = "Extra deposit"
        _ = try await store.save(addition)
        await context.reload()

        // The status this asserts on is load-bearing, not cosmetic: the app switches the
        // Home tab's stack root on it, so a momentary `.loading` here tore the navigation
        // stack down on every save, delete and undo — which is how saving from an editor
        // pushed two levels deep popped back onto an empty "Relief not found" screen.
        #expect(probe.statusesAtRuleSetLookup == [.loading, .ready])
        #expect(context.status == .ready)
    }

    @Test("a reload with nothing loaded yet is a cold load and says so")
    func reloadWithoutResultStillAnnouncesLoading() async throws {
        let store = try await PresentationFixture.store()

        let probe = LoadStatusProbe()
        let loader = ProbingRuleSetLoader(availableYears: [2025]) { probe.record() }
        let context = YearContext(store: store, loader: loader, year: 2025)
        probe.context = context

        // Onboarding finishes with a `reload()`, not a `load()`, and at that point there
        // is no result to preserve. Suppressing `.loading` there would leave the app on
        // its `.idle` spinner with no evidence anything was happening.
        await context.reload()

        #expect(probe.statusesAtRuleSetLookup == [.loading])
        #expect(context.status == .ready)
    }

    @Test("switching year remembers the choice for next launch")
    func lastViewedYearIsPersisted() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        await context.switchYear(to: 2024)

        #expect(try await store.preferences().lastViewedYear == 2024)
    }

    @Test("a malformed rulebook is reported differently from an unshipped year")
    func malformedRulebookDiffersFromUnshippedYear() async throws {
        let store = try await PresentationFixture.store()

        let malformedLoader = FailingRuleSetLoader(
            availableYears: [2025],
            error: .malformed(year: 2025, underlying: "truncated JSON"))
        let malformedContext = YearContext(store: store, loader: malformedLoader, year: 2025)
        await malformedContext.load()

        #expect(malformedContext.result == nil)
        guard case .unavailable(let malformedMessage) = malformedContext.status else {
            Issue.record("expected .unavailable, got \(malformedContext.status)")
            return
        }
        #expect(malformedMessage.contains("2025"))

        let unshippedLoader = FailingRuleSetLoader(
            availableYears: [2025],
            error: .noRulesForYear(2025))
        let unshippedContext = YearContext(store: store, loader: unshippedLoader, year: 2025)
        await unshippedContext.load()

        guard case .unavailable(let unshippedMessage) = unshippedContext.status else {
            Issue.record("expected .unavailable, got \(unshippedContext.status)")
            return
        }
        #expect(unshippedMessage.contains("2025"))

        // A corrupt rulebook must not read like a calm "not shipped yet" — the user
        // would otherwise wait for a Budget that has already happened.
        #expect(malformedMessage != unshippedMessage)
    }

    @Test("switching to an unavailable year and back leaves entries and figures intact")
    func roundTripThroughUnavailableYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()

        let originalLifestyle = try #require(
            context.result?.assessment(for: ReliefCode("LIFESTYLE"))?.claimed)
        let originalMedical = try #require(
            context.result?.assessment(for: ReliefCode("MEDICAL_CHECKUP"))?.claimed)
        let originalSSPN = try #require(
            context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)

        await context.switchYear(to: 2026)
        #expect(context.result == nil)
        guard case .unavailable = context.status else {
            Issue.record("expected .unavailable, got \(context.status)")
            return
        }

        await context.switchYear(to: 2025)
        #expect(context.status == .ready)
        #expect(context.result?.assessment(for: ReliefCode("LIFESTYLE"))?.claimed == originalLifestyle)
        #expect(context.result?.assessment(for: ReliefCode("MEDICAL_CHECKUP"))?.claimed == originalMedical)
        #expect(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed == originalSSPN)
    }

    @Test("a superseded load never writes its year's figures under another year's label")
    func overlappingSwitchesResolveToTheCurrentYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()

        // The two switches genuinely interleave, and deterministically so: 2024 has a
        // shipped rulebook, so its load suspends inside `store.project`; 2026 has none,
        // so its load fails synchronously and finishes first. Without a generation guard
        // the 2024 evaluation then lands *after* the year has already moved to 2026, and
        // every screen reads 2024's figures under a 2026 heading while the status claims
        // .ready — the worst kind of wrong for a tax app, because it looks correct.
        let first = Task { await context.switchYear(to: 2024) }
        let second = Task { await context.switchYear(to: 2026) }
        _ = await first.value
        _ = await second.value

        #expect(context.year == 2026)
        if let result = context.result {
            Issue.record("a superseded load assigned \(result.yearOfAssessment) while showing \(context.year)")
        }
        guard case .unavailable = context.status else {
            Issue.record("expected .unavailable for 2026, got \(context.status)")
            return
        }
        #expect(context.ruleSet == nil)
        // The superseded switch must not win the "resume here next launch" race either.
        #expect(try await store.preferences().lastViewedYear == 2026)
    }

    @Test("two overlapping switches leave the result matching the year on screen")
    func overlappingSwitchesAgreeOnTheYear() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()

        let first = Task { await context.switchYear(to: 2024) }
        let second = Task { await context.switchYear(to: 2023) }
        _ = await first.value
        _ = await second.value

        // Whichever wins, the invariant every screen depends on holds: the single shared
        // result describes the year the switcher is showing.
        let result = try #require(context.result)
        #expect(result.yearOfAssessment == context.year)
        #expect(context.status == .ready)
    }

    @Test("a no-op switch to the current ready year does not re-stamp preferences")
    func noOpSwitchDoesNotStampPreferences() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()

        await context.switchYear(to: 2024)
        let stampAfterRealSwitch = try #require(
            try await store.allPreferencesUpdatedAtForTesting().first)

        // Advance the clock so a re-stamp, if it happened, would be observable.
        await store.useClock { PresentationFixture.epoch.addingTimeInterval(3_600) }
        await context.switchYear(to: 2024)
        let stampAfterNoOp = try #require(
            try await store.allPreferencesUpdatedAtForTesting().first)

        #expect(stampAfterNoOp == stampAfterRealSwitch)
    }

    @Test("switching to a year already stored as lastViewedYear does not move the stored updatedAt")
    func rememberYearSkipsWriteWhenPreferenceAlreadyMatches() async throws {
        let store = try await PresentationFixture.store()

        // A real switch to 2024 first, so `UserPreferences.lastViewedYear` is genuinely
        // 2024 going into the scenario below — not merely its unwritten default.
        let firstContext = PresentationFixture.context(store, year: 2025)
        await firstContext.load()
        await firstContext.switchYear(to: 2024)
        #expect(try await store.preferences().lastViewedYear == 2024)

        let stampBeforeResume = try #require(
            try await store.allPreferencesUpdatedAtForTesting().first)

        // Advance the clock so a re-stamp, if it happened, would be observable.
        await store.useClock { PresentationFixture.epoch.addingTimeInterval(3_600) }

        // This mirrors `RootView.resumeLastViewedYear`: a fresh launch starts a new
        // `YearContext` on the newest available year, reads the remembered year back
        // from preferences, and calls `switchYear(to:)` to resume it. Because the
        // context's own `year` (2025) differs from the remembered year (2024),
        // `switchYear`'s top-level guard does not block this — it reloads and calls
        // `rememberYear(2024)` for real. Preferences already say 2024, so this must not
        // write, even though a genuine year change is happening from this context's
        // point of view.
        let resumedContext = PresentationFixture.context(store, year: 2025)
        await resumedContext.load()
        await resumedContext.switchYear(to: 2024)

        let stampAfterResume = try #require(
            try await store.allPreferencesUpdatedAtForTesting().first)

        #expect(stampAfterResume == stampBeforeResume)
    }
}
