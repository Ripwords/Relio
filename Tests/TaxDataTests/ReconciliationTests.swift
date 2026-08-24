import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Year reconciliation") struct YearReconciliationTests {

    @Test("two TaxYear rows for one year collapse, keeping the newest")
    func duplicateYearsCollapse() async throws {
        let store = try await StoreFixture.store()
        // The collision CloudKit can produce but one device cannot: two live TaxYear
        // rows for 2025, created offline on two devices before the first sync.
        var older = YearFacts()
        older.grossIncome = Money(ringgit: 100_000)
        try await store.saveYearFacts(older, for: 2025)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: Money(ringgit: 128_000))

        #expect(try await store.liveYearRowCount(2025) == 2)
        #expect(try await store.reconcileYears() == 1)
        #expect(try await store.liveYearRowCount(2025) == 1)
        #expect(try await store.yearFacts(for: 2025).grossIncome == Money(ringgit: 128_000))
    }

    @Test("the survivor adopts facts it does not have, and never overwrites its own")
    func factsMergeByFillingGaps() async throws {
        let store = try await StoreFixture.store()
        var older = YearFacts()
        older.grossIncome = Money(ringgit: 100_000)
        older.maritalStatus = .married          // the newer row will not have this
        try await store.saveYearFacts(older, for: 2025)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: Money(ringgit: 128_000))
        _ = try await store.reconcileYears()

        let facts = try await store.yearFacts(for: 2025)
        // Newer answer wins where both answered...
        #expect(facts.grossIncome == Money(ringgit: 128_000))
        // ...and an answer the user gave on their other phone is adopted, not discarded.
        // nil means "not answered yet" everywhere in this app, so filling a gap cannot
        // lose an answer.
        #expect(facts.maritalStatus == .married)
    }

    @Test("entries on a losing row are re-pointed, not orphaned")
    func entriesFollowTheSurvivor() async throws {
        let store = try await StoreFixture.store()
        // Three, not one: re-pointing mutates `entry.taxYear`, the inverse side of the
        // very relationship (`loser.entries`) being iterated. With a single entry a
        // skipped-element bug (e.g. mutating a collection while walking it) would still
        // pass by accident — this exercises "every entry arrives", not just "one did".
        _ = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820, vendor: "Popular Bookstore"))
        _ = try await store.save(StoreFixture.entry("SSPN", 3_000, vendor: "SSPN"))
        _ = try await store.save(StoreFixture.entry("MEDICAL_SERIOUS", 6_500, vendor: "Hospital"))

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: nil)
        _ = try await store.reconcileYears()

        // All three entries were attached to the row that lost. If they were not
        // re-pointed they would hang off a soft-deleted year and vanish from the user's
        // own records.
        let drafts = try await store.entryDrafts(forYear: 2025)
        #expect(drafts.count == 3)
        #expect(Set(drafts.map(\.code)) == [ReliefCode("LIFESTYLE"), ReliefCode("SSPN"), ReliefCode("MEDICAL_SERIOUS")])
    }

    @Test("two devices seeing the same year rows in opposite orders pick the same survivor")
    func yearSweepIsOrderIndependent() async throws {
        let idA = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        let idB = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        let instant = StoreFixture.epoch

        let deviceOne = try await StoreFixture.store()
        try await deviceOne.insertDuplicateYearForTesting(id: idA, year: 2025, updatedAt: instant, grossIncome: nil)
        try await deviceOne.insertDuplicateYearForTesting(id: idB, year: 2025, updatedAt: instant, grossIncome: nil)

        let deviceTwo = try await StoreFixture.store()
        try await deviceTwo.insertDuplicateYearForTesting(id: idB, year: 2025, updatedAt: instant, grossIncome: nil)
        try await deviceTwo.insertDuplicateYearForTesting(id: idA, year: 2025, updatedAt: instant, grossIncome: nil)

        #expect(try await deviceOne.reconcileYears() == 1)
        #expect(try await deviceTwo.reconcileYears() == 1)

        let survivorOne = try await deviceOne.liveYearIdsForTesting(year: 2025).first
        let survivorTwo = try await deviceTwo.liveYearIdsForTesting(year: 2025).first
        // Identical stamps, so the tie-break (shared with `TaxStore.isNewer`, not a
        // second copy of it) is doing the work. Without it two devices could pick
        // different survivors and resurrect each other's soft-deleted loser forever.
        #expect(survivorOne == survivorTwo)
        #expect(survivorOne == idB, "highest uuidString wins the tie")
    }

    @Test("running year reconciliation twice changes nothing the second time")
    func yearSweepIsIdempotent() async throws {
        let store = try await StoreFixture.store()
        try await store.saveYearFacts(YearFacts(), for: 2025)
        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateYearForTesting(2025, grossIncome: nil)

        #expect(try await store.reconcileYears() == 1)
        #expect(try await store.reconcileYears() == 0)
    }

    @Test("distinct years are left alone")
    func distinctYearsSurvive() async throws {
        let store = try await StoreFixture.store()
        try await store.saveYearFacts(YearFacts(), for: 2024)
        try await store.saveYearFacts(YearFacts(), for: 2025)
        #expect(try await store.reconcileYears() == 0)
        #expect(try await store.liveYears() == [2024, 2025])
    }
}

@Suite("Reconciliation") struct ReconciliationTests {

    static let t0 = StoreFixture.epoch
    static let t1 = StoreFixture.epoch.addingTimeInterval(60)

    /// Saves a draft at a controlled instant, so tests can pin which row is "newest".
    static func save(_ store: TaxStore, _ draft: EntryDraft, at instant: Date) async throws -> UUID {
        await store.useClock { instant }
        return try await store.save(draft)
    }

    @Test("a duplicate collapses onto the newest row")
    func duplicateCollapses() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        #expect(reports.first?.survivorID == newer.id)
        #expect(reports.first?.mergedIDs == [older.id])

        let live = try await store.entryDrafts(forYear: 2025)
        #expect(live.count == 1)
        #expect(live.first?.id == newer.id)
        #expect(try await store.mergedInto(entryID: older.id) == newer.id)
    }

    @Test("the survivor inherits the losers' documents, and needsDocument reflects them")
    func documentLinksAreUnioned() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("MEDICAL_SERIOUS", 6_500)
        var newer = StoreFixture.entry("MEDICAL_SERIOUS", 6_500)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        // The older row is the one that carries the medical certificate. Dropping it
        // would turn a complete claim into one failing its requirement check — the merge
        // would destroy evidence, which is the one thing it must never do. Attached at
        // two distinct, increasing instants (both later than either save) so the
        // survivor is genuinely chosen because it is newest — pinning both attaches to
        // the same instant would instead exercise the uuid tie-break, which is not what
        // this test is about.
        try await store.attachDocumentForTesting(kind: .medicalCertificate, toEntry: older.id)
        await store.useClock { Self.t1.addingTimeInterval(60) }
        try await store.attachDocumentForTesting(kind: .officialReceipt, toEntry: newer.id)

        _ = try await store.reconcile()

        let survivor = try #require(try await store.entryDrafts(forYear: 2025).first)
        #expect(survivor.id == newer.id)
        #expect(survivor.documentKinds == [.medicalCertificate, .officialReceipt])
        // needsDocument is cached and only recomputed on a write to the row. MEDICAL_SERIOUS
        // requires both officialReceipt and medicalCertificate; the union satisfies that
        // requirement, so without a recompute on the survivor this would still read true —
        // the exact case the union exists to fix would still show as incomplete.
        #expect(survivor.needsDocument == false)
    }

    @Test("two devices seeing the same rows in opposite orders pick the same survivor")
    func sweepIsOrderIndependent() async throws {
        var a = StoreFixture.entry("LIFESTYLE", 1_820)
        var b = StoreFixture.entry("LIFESTYLE", 1_820)
        a.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        b.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!

        let deviceOne = try await StoreFixture.store()
        _ = try await Self.save(deviceOne, a, at: Self.t0)
        _ = try await Self.save(deviceOne, b, at: Self.t0)

        let deviceTwo = try await StoreFixture.store()
        _ = try await Self.save(deviceTwo, b, at: Self.t0)
        _ = try await Self.save(deviceTwo, a, at: Self.t0)

        let one = try await deviceOne.reconcile()
        let two = try await deviceTwo.reconcile()

        // Identical stamps, so the tie-break is doing the work. Without it the two
        // devices pick different survivors, then resurrect each other's soft-deleted
        // rows on the next sync and the duplicate never goes away.
        #expect(one.first?.survivorID == two.first?.survivorID)
        #expect(one.first?.survivorID == b.id, "highest uuidString wins the tie")
    }

    @Test("a three-way duplicate collapses to one row")
    func threeWayCollapse() async throws {
        let store = try await StoreFixture.store()
        for (index, instant) in [Self.t0, Self.t1, Self.t0].enumerated() {
            var draft = StoreFixture.entry("SSPN", 3_000)
            draft.id = UUID(uuidString: "00000000-0000-0000-0000-00000000000\(index)")!
            _ = try await Self.save(store, draft, at: instant)
        }
        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        #expect(reports.first?.mergedIDs.count == 2)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("running the sweep twice changes nothing the second time")
    func sweepIsIdempotent() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)

        #expect(try await store.reconcile().count == 1)
        // The sweep runs on every sync-complete event. If it were not idempotent it
        // would churn updatedAt on every sync, which would in turn look like a change
        // to every other device — an infinite sync loop.
        #expect(try await store.reconcile().isEmpty)
        #expect(try await store.entryDrafts(forYear: 2025).count == 1)
    }

    @Test("entries that merely look similar are left alone")
    func distinctEntriesSurvive() async throws {
        let store = try await StoreFixture.store()
        var a = StoreFixture.entry("LIFESTYLE", 1_820, vendor: "Popular Bookstore")
        var b = StoreFixture.entry("LIFESTYLE", 1_820, vendor: "MPH Bookstores")
        var c = StoreFixture.entry("LIFESTYLE", 1_821, vendor: "Popular Bookstore")
        a.id = UUID(); b.id = UUID(); c.id = UUID()
        for draft in [a, b, c] { _ = try await Self.save(store, draft, at: Self.t0) }

        #expect(try await store.reconcile().isEmpty)
        #expect(try await store.entryDrafts(forYear: 2025).count == 3)
    }

    @Test("a merge can be undone")
    func unmergeRestores() async throws {
        let store = try await StoreFixture.store()
        var older = StoreFixture.entry("LIFESTYLE", 1_820)
        var newer = StoreFixture.entry("LIFESTYLE", 1_820)
        older.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
        newer.id = UUID(uuidString: "00000000-0000-0000-0000-0000000000BB")!
        _ = try await Self.save(store, older, at: Self.t0)
        _ = try await Self.save(store, newer, at: Self.t1)
        _ = try await store.reconcile()

        try await store.unmerge(entryID: older.id)
        let live = try await store.entryDrafts(forYear: 2025)
        // An automatic, irreversible merge of someone's tax records is not something
        // this app should be able to do. Spec §6.4 requires the merge be reversible.
        #expect(live.count == 2)
        #expect(try await store.mergedInto(entryID: older.id) == nil)
    }
}
