import Testing
import Foundation
import TaxKit
import TaxData
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

@Suite("YearContext") @MainActor struct YearContextTests {

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
}
