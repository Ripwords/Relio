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
        facts.grossIncome = Money(ringgit: 128_000)
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
}
