import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

/// Builders shared by the store, dedupe and reconciliation suites.
enum StoreFixture {

    static let epoch = Date(timeIntervalSince1970: 1_750_000_000)   // 2025-06-15 UTC

    static func store(at instant: Date = epoch) async throws -> TaxStore {
        let container = try TaxContainer.make(.inMemory)
        let store = TaxStore(modelContainer: container)
        await store.useClock { instant }
        return store
    }

    static func entry(_ code: String,
                      _ ringgit: Decimal,
                      year: Int = 2025,
                      vendor: String = "Popular Bookstore",
                      spentOn: Date? = Date(timeIntervalSince1970: 1_740_000_000)) -> EntryDraft {
        EntryDraft(year: year,
                   code: ReliefCode(code),
                   amount: Money(ringgit: ringgit),
                   vendor: vendor,
                   spentOn: spentOn)
    }
}

@Suite("TaxStore") struct TaxStoreTests {

    @Test("saving an entry creates its year on demand")
    func savingCreatesTheYear() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        let years = try await store.liveYears()
        #expect(years == [2025])
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1)
        #expect(drafts.first?.code == ReliefCode("LIFESTYLE"))
        #expect(drafts.first?.amount == Money(ringgit: 1_820))
    }

    @Test("every write stamps updatedAt from the injected clock")
    func writesAreStamped() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        var drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.first?.updatedAt == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        var edited = try #require(drafts.first)
        edited.amount = Money(ringgit: 2_000)
        _ = try await store.save(edited)

        drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1, "editing must update in place, not insert a second row")
        #expect(drafts.first?.id == id)
        #expect(drafts.first?.amount == Money(ringgit: 2_000))
        #expect(drafts.first?.updatedAt == later)
    }

    @Test("deleting is soft and reversible")
    func softDeleteAndRestore() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        try await store.softDeleteEntry(id: id)
        #expect(try await store.entryDrafts(forYear: 2025).isEmpty)

        // Spec §11.6: every destructive action is undoable. A hard delete would make the
        // undo toast a lie, and would let a delete on one device beat a concurrent edit
        // on another into permanent data loss.
        try await store.restoreEntry(id: id)
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1)
        #expect(drafts.first?.id == id)
    }

    @Test("deleting a missing entry is a no-op, not a throw")
    func deletingMissingIsNoOp() async throws {
        let store = try await StoreFixture.store()
        // The same delete can arrive twice — an undo toast tapped as a sync lands. It
        // must be idempotent, or the second one crashes a screen the user is looking at.
        try await store.softDeleteEntry(id: UUID())
        #expect(try await store.liveYears().isEmpty)
    }

    @Test("year facts round-trip and stamp the year")
    func yearFacts() async throws {
        let store = try await StoreFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        let read = try await store.yearFacts(for: 2025)
        #expect(read.grossIncome == Money(ringgit: 128_000))
        #expect(read.maritalStatus == .married)
        #expect(read.spouseHasIncome == false)
        #expect(read.propertyPrice == Money(ringgit: 480_000))
    }

    @Test("an unknown year reads as empty facts rather than throwing")
    func unknownYearIsEmpty() async throws {
        let store = try await StoreFixture.store()
        let facts = try await store.yearFacts(for: 2023)
        // Empty, not absent: every optional means "not yet known", which the engine
        // renders as a prompt. Throwing here would make the Home screen an error screen
        // for anyone who switches to a year they have not filled in.
        #expect(facts.grossIncome == nil)
        #expect(facts.maritalStatus == nil)
    }

    @Test("dependents round-trip with their per-year statuses")
    func dependents() async throws {
        let store = try await StoreFixture.store()
        var draft = DependentDraft(name: "Farah")
        draft.kind = .child
        draft.dateOfBirth = Date(timeIntervalSince1970: 1_253_491_200)   // 2009-09-21
        draft.yearStatuses = [DependentYearStatus(year: 2025,
                                                  educationLevel: .preTertiary,
                                                  claimPercentage: 50,
                                                  isFullTime: true)]
        let id = try await store.save(draft)

        let all = try await store.dependentDrafts()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.yearStatuses.first?.claimPercentage == 50)
    }

    @Test("two preference rows collapse to the newest")
    func preferencesCollisionResolves() async throws {
        let store = try await StoreFixture.store()

        var first = PreferencesSnapshot()
        first.incomeModuleEnabled = false
        try await store.savePreferences(first)

        // Simulate the offline-first-launch collision: a second row arrives from another
        // device with a later stamp. CloudKit cannot enforce a singleton, so the store
        // resolves it by the same rule the sweep uses — newest updatedAt wins.
        let later = StoreFixture.epoch.addingTimeInterval(60)
        await store.useClock { later }
        try await store.insertDuplicatePreferencesForTesting(incomeModuleEnabled: true)

        let resolved = try await store.preferences()
        #expect(resolved.incomeModuleEnabled == true)
        #expect(try await store.livePreferenceRowCount() == 1)
    }
}
