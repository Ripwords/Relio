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
        facts.grossIncomeOverride = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        let read = try await store.yearFacts(for: 2025)
        #expect(read.grossIncomeOverride == Money(ringgit: 128_000))
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
        #expect(facts.grossIncomeOverride == nil)
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

        // Fix D: the loser must be stamped with the clock active when it lost, not left
        // at its original `updatedAt` — otherwise its soft delete syncs with a stale
        // stamp and can lose to an older edit under newest-write-wins.
        let stamps = try await store.allPreferencesUpdatedAtForTesting()
        #expect(stamps.allSatisfy { $0 == later },
                "every preferences row, survivor and loser alike, must carry the stamp active when the collision was resolved")
    }

    @Test("saving preferences while a duplicate exists also stamps the loser, not just reading does")
    func savePreferencesConsolidatesDuplicates() async throws {
        // Fix D: `resolvedPreferencesRow` is shared by the write path (`savePreferences`)
        // and the read path (`preferences`). This exercises the write path with a
        // pre-existing collision, so a regression that re-splits the two resolvers would
        // be caught here even if `preferences()` alone still looked fine.
        let store = try await StoreFixture.store()

        var first = PreferencesSnapshot()
        first.incomeModuleEnabled = false
        try await store.savePreferences(first)

        let later = StoreFixture.epoch.addingTimeInterval(60)
        await store.useClock { later }
        try await store.insertDuplicatePreferencesForTesting(incomeModuleEnabled: true)

        let evenLater = StoreFixture.epoch.addingTimeInterval(120)
        await store.useClock { evenLater }
        var updated = PreferencesSnapshot()
        updated.incomeModuleEnabled = true
        updated.lastViewedYear = 2025
        try await store.savePreferences(updated)

        #expect(try await store.livePreferenceRowCount() == 1)
        let resolved = try await store.preferences()
        #expect(resolved.lastViewedYear == 2025)

        let stamps = try await store.allPreferencesUpdatedAtForTesting()
        #expect(stamps.allSatisfy { $0 == evenLater },
                "the write path must stamp a loser it consolidates, exactly as the read path does")
    }

    @Test("entryDrafts filters strictly by year and orders ascending by id")
    func entryDraftsFilterByYearAndOrder() async throws {
        // Fix A: every one of the other tests populates a single year, so all 8 would
        // still pass if `entryDrafts(forYear:)`'s predicate degraded to `deletedAt ==
        // nil` alone. This is the permanent regression guard the reviewer asked for,
        // plus the never-before-exercised ascending-id ordering guarantee.
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE", 100, year: 2024))
        let idA = try await store.save(StoreFixture.entry("LIFESTYLE", 200, year: 2025))
        let idB = try await store.save(StoreFixture.entry("LIFESTYLE", 300, year: 2025))

        let drafts2025 = try await store.entryDrafts(forYear: 2025)
        #expect(drafts2025.count == 2)
        #expect(Set(drafts2025.map(\.id)) == Set([idA, idB]))
        let expectedOrder = [idA, idB].sorted { $0.uuidString < $1.uuidString }
        #expect(drafts2025.map(\.id) == expectedOrder,
                "entries must come back ordered ascending by id.uuidString so two devices agree")

        let drafts2024 = try await store.entryDrafts(forYear: 2024)
        #expect(drafts2024.count == 1)
    }

    @Test("a repeated delete does not re-stamp updatedAt, so it cannot outrace a concurrent edit or restore")
    func repeatedDeleteDoesNotRestamp() async throws {
        // Fix C: the earlier `softDeleteAndRestore` test only ever deletes once, so it
        // could not catch a replayed delete re-stamping `updatedAt`. Advancing the clock
        // between the two deletes is what makes that regression visible.
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))

        try await store.softDeleteEntry(id: id)
        let firstStamp = try await store.entryUpdatedAtForTesting(id: id)
        #expect(firstStamp == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        try await store.softDeleteEntry(id: id)   // replayed delete, e.g. an undo tapped as a sync lands
        let secondStamp = try await store.entryUpdatedAtForTesting(id: id)
        #expect(secondStamp == firstStamp,
                "a replayed delete on an already-deleted row must not acquire a newer stamp")
    }

    @Test("a repeated dependent delete does not re-stamp updatedAt either")
    func repeatedDependentDeleteDoesNotRestamp() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(DependentDraft(name: "Farah"))

        try await store.softDeleteDependent(id: id)
        let firstStamp = try await store.dependentUpdatedAtForTesting(id: id)
        #expect(firstStamp == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        try await store.softDeleteDependent(id: id)
        let secondStamp = try await store.dependentUpdatedAtForTesting(id: id)
        #expect(secondStamp == firstStamp)
    }

    @Test("editing a merged-away entry clears mergedInto, agreeing with restoreEntry")
    func saveClearsMergedInto() async throws {
        // Fix B: `restoreEntry` clears both `deletedAt` and `mergedInto`. `save` cleared
        // only `deletedAt`, so editing an entry Task 6's sweep merged away would revive
        // it live while it still pointed at its merge target.
        let store = try await StoreFixture.store()
        let draft = StoreFixture.entry("LIFESTYLE", 1_820)
        let id = try await store.save(draft)

        // Simulate what the reconciliation sweep does to a losing row.
        try await store.softDeleteEntry(id: id)
        try await store.setMergedIntoForTesting(id: id, mergedInto: UUID())

        _ = try await store.save(draft)   // draft.id == id: an edit, not a new entry

        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 1, "editing a merged-away entry must revive it, same as restoreEntry")
        #expect(try await store.entryMergedIntoForTesting(id: id) == nil,
                "save must clear mergedInto the same way restoreEntry does, or the revived row still points at a merge target")
    }

    @Test("two devices agree on which duplicate TaxYear row is the read/write target")
    func duplicateYearRowsResolveDeterministically() async throws {
        // Fix E: `fetchOrCreateYear` and `yearFacts` each took `.first` of an unsorted
        // fetch. Two devices first launching offline can each create a live
        // `TaxYear(2025)` row, and household income must not depend on which happens to
        // come back from an unordered fetch. Scope limit: this does not merge or
        // soft-delete the loser row — that is Task 6's job — only the selection must be
        // deterministic.
        let store = try await StoreFixture.store()
        var facts = YearFacts()
        facts.grossIncomeOverride = Money(ringgit: 50_000)
        try await store.saveYearFacts(facts, for: 2025)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        try await store.insertDuplicateYearForTesting(year: 2025,
                                                       updatedAt: later,
                                                       grossIncomeOverride: Money(ringgit: 99_000))

        // The read path must pick the newer (duplicate) row.
        let read = try await store.yearFacts(for: 2025)
        #expect(read.grossIncomeOverride == Money(ringgit: 99_000))

        // The write path must land on that same row, not create a third row or silently
        // mutate the older loser.
        var updated = YearFacts()
        updated.grossIncomeOverride = Money(ringgit: 120_000)
        try await store.saveYearFacts(updated, for: 2025)

        let incomes = try await store.liveYearGrossIncomeOverridesForTesting(year: 2025)
        #expect(incomes.count == 2, "the loser row must still exist — Task 4 does not merge duplicate TaxYear rows")
        #expect(incomes.first == Money(ringgit: 120_000), "the write must have landed on the survivor the read path also picks")
        #expect(incomes.last == Money(ringgit: 50_000), "the loser row must be left untouched, not merged away")
    }

    @Test("duplicate TaxYear rows with identical updatedAt resolve deterministically by id")
    func duplicateYearRowsWithSameStampBreakTiesByID() async throws {
        // Fix round 2: the round-1 tie-break used persistentModelID, a *local store*
        // identity not guaranteed to agree across two devices for the same logical row.
        // TaxYear.id is now the stable, cross-device tie-break — the same rule every
        // other resolver in TaxStore already applies (newest updatedAt, ties on
        // id.uuidString, higher string wins). Fixed UUIDs pin the expectation instead of
        // leaving it incidental on whatever order two random UUIDs happen to compare in.
        let store = try await StoreFixture.store()
        let lowerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let higherID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!

        try await store.insertDuplicateYearForTesting(id: lowerID,
                                                       year: 2025,
                                                       updatedAt: StoreFixture.epoch,
                                                       grossIncomeOverride: Money(ringgit: 10_000))
        try await store.insertDuplicateYearForTesting(id: higherID,
                                                       year: 2025,
                                                       updatedAt: StoreFixture.epoch,
                                                       grossIncomeOverride: Money(ringgit: 20_000))

        let ids = try await store.liveYearIdsForTesting(year: 2025)
        #expect(ids.first == higherID,
                "with updatedAt tied, the row with the higher id.uuidString must win, deterministically on every run")
        #expect(ids == ids.sorted { $0.uuidString > $1.uuidString })

        let read = try await store.yearFacts(for: 2025)
        #expect(read.grossIncomeOverride == Money(ringgit: 20_000), "yearFacts must read through the id-tie-break survivor")
    }
}
