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
}
