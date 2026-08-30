import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Income store") struct IncomeStoreTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    @Test("saving a source and a rate round-trips")
    func saveAndRead() async throws {
        let store = try await StoreFixture.store()
        var job = IncomeSourceDraft(name: "Main job")
        job.deductsEPF = true
        let sourceID = try await store.save(job)

        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.shape = .recurring
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)

        let sources = try await store.incomeSourceDrafts()
        #expect(sources.count == 1)
        #expect(sources.first?.name == "Main job")
        #expect(sources.first?.deductsEPF == true)

        let records = try await store.incomeRecordDrafts(forSource: sourceID)
        #expect(records.count == 1)
        #expect(records.first?.amount == Money(ringgit: 8_000))
    }

    @Test("an unasked deduction stays nil through a round trip")
    func unaskedDeductionsSurvive() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(IncomeSourceDraft(name: "Design freelance"))
        let read = try await store.incomeSourceDrafts().first
        // Coercing these to false would claim the user confirmed no EPF, which they did not.
        #expect(read?.deductsEPF == nil)
        #expect(read?.deductsSOCSO == nil)
    }

    @Test("every write stamps updatedAt from the injected clock")
    func writesAreStamped() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(IncomeSourceDraft(name: "Main job"))
        #expect(try await store.incomeSourceUpdatedAtForTesting(id) == StoreFixture.epoch)

        let later = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { later }
        var edited = try #require(try await store.incomeSourceDrafts().first)
        edited.name = "Main job (renamed)"
        _ = try await store.save(edited)
        #expect(try await store.incomeSourceUpdatedAtForTesting(id) == later)
    }

    @Test("editing updates in place rather than inserting a second row")
    func editInPlace() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(IncomeSourceDraft(name: "Main job"))
        var edited = try #require(try await store.incomeSourceDrafts().first)
        edited.kind = .occasional
        _ = try await store.save(edited)

        let all = try await store.incomeSourceDrafts()
        #expect(all.count == 1)
        #expect(all.first?.id == id)
        #expect(all.first?.kind == .occasional)
    }

    @Test("deleting is soft, and a deleted record stops counting")
    func softDeleteRemovesFromDerivation() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        let rateID = try await store.save(rate)

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
        try await store.softDeleteIncomeRecord(id: rateID)
        // A deleted raise that still counted would silently inflate the year's income.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
        #expect(try await store.incomeRecordDrafts(forSource: sourceID).isEmpty)
    }

    @Test("deleting a source removes its records from the derivation too")
    func deletingSourceRemovesItsIncome() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)

        try await store.softDeleteIncomeSource(id: sourceID)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
        #expect(try await store.incomeSourceDrafts().isEmpty)
    }

    @Test("the store reproduces the spec's worked example end to end")
    func workedExample() async throws {
        let store = try await StoreFixture.store()
        let jobID = try await store.save(IncomeSourceDraft(name: "Main job"))
        for (ringgit, from) in [(Decimal(8_000), Self.date(2025, 1, 1)),
                                (Decimal(9_500), Self.date(2025, 4, 15))] {
            var rate = IncomeRecordDraft(sourceID: jobID)
            rate.amount = Money(ringgit: ringgit)
            rate.effectiveFrom = from
            _ = try await store.save(rate)
        }

        var side = IncomeSourceDraft(name: "Design freelance")
        side.kind = .occasional
        let sideID = try await store.save(side)
        for (ringgit, on) in [(Decimal(1_800), Self.date(2025, 3, 14)),
                              (Decimal(2_400), Self.date(2025, 7, 2)),
                              (Decimal(950), Self.date(2025, 11, 9))] {
            var payment = IncomeRecordDraft(sourceID: sideID)
            payment.shape = .oneOff
            payment.amount = Money(ringgit: ringgit)
            payment.effectiveFrom = on
            _ = try await store.save(payment)
        }

        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 113_950))
    }

    @Test("snapshots are ordered deterministically")
    func snapshotsAreOrdered() async throws {
        let store = try await StoreFixture.store()
        for name in ["Main job", "Design freelance", "Tutoring"] {
            _ = try await store.save(IncomeSourceDraft(name: name))
        }
        let first = try await store.incomeSnapshots().map(\.id)
        let second = try await store.incomeSnapshots().map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("updating a record whose source has vanished throws rather than orphaning it")
    func updatingIntoAnUnknownSourceThrows() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        let recordID = try await store.save(rate)

        // Re-pointing an existing record at a source that does not exist used to take the
        // update branch, which set `row.source = nil` — the same orphaning the insert
        // branch throws to prevent, reached down the other side of the same `if`.
        var moved = IncomeRecordDraft(id: recordID, sourceID: UUID())
        moved.amount = Money(ringgit: 8_000)
        moved.effectiveFrom = Self.date(2025, 1, 1)
        await #expect(throws: IncomeStoreError.self) { try await store.save(moved) }

        // And the record is untouched, still under the source it had.
        #expect(try await store.incomeRecordDrafts(forSource: sourceID).count == 1)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("one summary call answers the subtotals, the sources and the known/unknown year")
    func summaryAnswersTheYearInOneRead() async throws {
        let store = try await StoreFixture.store()
        var job = IncomeSourceDraft(name: "Main job")
        job.deductsEPF = true
        let jobID = try await store.save(job)
        var rate = IncomeRecordDraft(sourceID: jobID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)

        let summary = try await store.incomeSummary(for: 2025)
        #expect(summary.rows.count == 1)
        let row = try #require(summary.rows.first)
        #expect(row.source.id == jobID)
        // The whole draft, not the name and kind the list happens to show: an edit
        // round-trips this back through `save`, which overwrites every field it carries.
        #expect(row.source.deductsEPF == true)
        #expect(row.total == Money(ringgit: 96_000))
        #expect(row.records.count == 1)
        #expect(summary.knownTotal == Money(ringgit: 96_000))

        // A year the timeline never reaches lists its sources but has no figure. `nil`,
        // not zero: the same answer `project(year:)` hands the engine.
        let earlier = try await store.incomeSummary(for: 2024)
        #expect(earlier.knownTotal == nil)
        #expect(earlier.rows.count == 1)
        #expect(earlier.rows.first?.total == Money.zero)
    }

    @Test("saving a record against an unknown source throws instead of orphaning it")
    func unknownSourceThrows() async throws {
        let store = try await StoreFixture.store()
        let phantomSourceID = UUID()
        var rate = IncomeRecordDraft(sourceID: phantomSourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)

        // Saving this silently would leave a record with no live source: invisible to
        // incomeRecordDrafts(forSource:) and to the derivation, understating the year's
        // income with no signal to the caller — exactly what onboarding's
        // `(try? await store.save(...)) ?? UUID()` fallback would trigger.
        await #expect(throws: IncomeStoreError.unknownIncomeSource(phantomSourceID)) {
            try await store.save(rate)
        }

        #expect(try await store.incomeSourceDrafts().isEmpty)
        #expect(try await store.incomeRecordDrafts(forSource: phantomSourceID).isEmpty)
    }

    // MARK: - A source CloudKit delivered twice

    /// Two live rows asserting `WellKnownID.primaryEmployment`, each with its own row for
    /// the same rate identity — what a second device's onboarding puts on disk. Nothing
    /// has swept, and nothing needs to have.
    private static func storeWithADuplicatedMainJob() async throws -> TaxStore {
        let store = try await StoreFixture.store()
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: Self.date(2025, 1, 1))
        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: Self.date(2025, 1, 1))
        return store
    }

    @Test("a year's derived gross does not double while a duplicate source is still on disk")
    func duplicateSourceDoesNotDoubleTheYear() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        #expect(try await store.liveIncomeSourceRowCountForTesting(
            id: WellKnownID.primaryEmployment) == 2)

        // The read resolves the identity group. The sweep has not run and is not what
        // makes this figure right — which is why the user's number is correct on a build
        // where nothing ever calls `reconcile()`.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
        #expect(try await store.incomeSourceDrafts().count == 1)
    }

    @Test("a duplicated source's records are read as one timeline, not one row's half")
    func duplicateSourceRecordsAreUnioned() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        let records = try await store.incomeRecordDrafts(forSource: WellKnownID.primaryEmployment)
        // Both physical rows carry the same rate identity, so the timeline shows one rate.
        #expect(records.count == 1)
        #expect(records.first?.amount == Money(ringgit: 8_000))
    }

    @Test("a duplicated source shows one row on the Income screen, not two")
    func duplicateSourceShowsOneSummaryRow() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        let summary = try await store.incomeSummary(for: 2025)
        // Two phantom rows carrying the same source and the same records with different
        // subtotals is what the screen used to render, and neither of them added up.
        #expect(summary.rows.count == 1)
        #expect(summary.rows.first?.total == Money(ringgit: 96_000))
        #expect(summary.rows.first?.records.count == 1)
        #expect(summary.knownTotal == Money(ringgit: 96_000))
    }

    @Test("an edit lands on the row the read path considers authoritative")
    func editsTargetTheSurvivor() async throws {
        let store = try await StoreFixture.store()
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: Self.date(2025, 1, 1))
        // The second row arrives from a phone whose clock runs an hour ahead of this one.
        await store.useClock { StoreFixture.epoch.addingTimeInterval(3_600) }
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: Self.date(2025, 1, 1))

        await store.useClock { StoreFixture.epoch.addingTimeInterval(60) }
        var draft = try #require(try await store.incomeSourceDrafts().first)
        draft.name = "Day job"
        draft.deductsEPF = true
        try await store.save(draft)

        // Writing to an arbitrary row and stamping it with the slower clock leaves the
        // edit ranked below the other phone's row, so the user's rename simply vanishes
        // on the next read.
        let read = try #require(try await store.incomeSourceDrafts().first)
        #expect(read.name == "Day job")
        #expect(read.deductsEPF == true)
    }

    @Test("deleting a duplicated source deletes every row sharing its id")
    func deletingRemovesTheWholeIdentity() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        try await store.softDeleteIncomeSource(id: WellKnownID.primaryEmployment)

        // Deleting one of two leaves the other live and the read resolves to it: the user
        // deletes their job and watches it come back.
        #expect(try await store.liveIncomeSourceRowCountForTesting(
            id: WellKnownID.primaryEmployment) == 0)
        #expect(try await store.incomeSourceDrafts().isEmpty)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
    }

    @Test("deleting a duplicated record deletes every row sharing its id")
    func deletingRemovesTheWholeRecordIdentity() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        let rateID = WellKnownID.openingRate(forSource: WellKnownID.primaryEmployment,
                                             effectiveFrom: Self.date(2025, 1, 1))
        try await store.softDeleteIncomeRecord(id: rateID)

        #expect(try await store.liveIncomeRecordRowCountForTesting(id: rateID) == 0)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money.zero)
    }
}
