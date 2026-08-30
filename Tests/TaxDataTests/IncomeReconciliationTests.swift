import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

/// Hand-built `@Model` rows for the pure merge policy, which needs no store and no clock.
enum IdentityGroupFixture {

    static func context() throws -> ModelContext {
        ModelContext(try TaxContainer.make(.inMemory))
    }

    @discardableResult
    static func source(in context: ModelContext,
                       id: UUID,
                       name: String = "Main job",
                       kind: IncomeKind = .employment,
                       deductsEPF: Bool? = nil,
                       deductsSOCSO: Bool? = nil,
                       endedOn: Date? = nil,
                       updatedAt: Date) -> IncomeSource {
        let row = IncomeSource(id: id, name: name)
        row.kind = kind
        row.deductsEPF = deductsEPF
        row.deductsSOCSO = deductsSOCSO
        row.endedOn = endedOn
        row.updatedAt = updatedAt
        context.insert(row)
        return row
    }

    @discardableResult
    static func rate(in context: ModelContext,
                     id: UUID = UUID(),
                     on source: IncomeSource,
                     shape: IncomeShape = .recurring,
                     ringgit: Decimal,
                     effectiveFrom: Date,
                     updatedAt: Date) -> IncomeRecord {
        let row = IncomeRecord(id: id)
        row.shape = shape
        row.amount = Money(ringgit: ringgit)
        row.effectiveFrom = effectiveFrom
        row.updatedAt = updatedAt
        row.source = source
        context.insert(row)
        return row
    }
}

@Suite("Income identity resolution") struct IncomeIdentityResolutionTests {

    static let epoch = StoreFixture.epoch
    static let identity = WellKnownID.primaryEmployment

    @Test("two rows sharing an id resolve to one source, keeping the newest")
    func sharedIdentityResolvesToOne() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: Self.identity, name: "Main job",
                                    updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: context, id: Self.identity, name: "Day job",
                                    updatedAt: Self.epoch.addingTimeInterval(60))

        let resolved = ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>()))
        #expect(resolved.count == 1)
        #expect(resolved.first?.survivor.name == "Day job")
        #expect(resolved.first?.group.count == 2)
    }

    @Test("the survivor adopts deduction answers only a losing row carries")
    func deductionAnswersFillGaps() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: Self.identity, deductsEPF: true,
                                    deductsSOCSO: true, updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: context, id: Self.identity, deductsEPF: false,
                                    updatedAt: Self.epoch.addingTimeInterval(60))

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        // The newer device answered EPF, so its answer stands...
        #expect(resolved.deductsEPF == false)
        // ...and the answer only the older phone has is adopted, not discarded. `nil` is
        // "not asked yet" everywhere here, so filling a gap cannot lose an answer.
        #expect(resolved.deductsSOCSO == true)
    }

    @Test("an end date is never gap-filled from a losing row")
    func endDateIsNotGapFilled() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: Self.identity,
                                    endedOn: IncomeStoreTests.date(2025, 9, 30),
                                    updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: context, id: Self.identity, endedOn: nil,
                                    updatedAt: Self.epoch.addingTimeInterval(60))

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        // The user reopened the job on the newer device. Adopting the older row's end date
        // would silently re-end it and understate the year.
        #expect(resolved.endedOn == nil)
    }

    @Test("records from every row in the group are read as one timeline")
    func recordsAreUnioned() throws {
        let context = try IdentityGroupFixture.context()
        let older = IdentityGroupFixture.source(in: context, id: Self.identity, updatedAt: Self.epoch)
        let newer = IdentityGroupFixture.source(in: context, id: Self.identity,
                                                updatedAt: Self.epoch.addingTimeInterval(60))
        IdentityGroupFixture.rate(in: context, on: older, ringgit: 8_000,
                                  effectiveFrom: IncomeStoreTests.date(2025, 1, 1),
                                  updatedAt: Self.epoch)
        IdentityGroupFixture.rate(in: context, on: newer, ringgit: 9_000,
                                  effectiveFrom: IncomeStoreTests.date(2025, 7, 1),
                                  updatedAt: Self.epoch)

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        // Reading only the survivor's records would show one figure now and a different
        // one after the sweep re-points the loser's.
        #expect(resolved.records.count == 2)
    }

    @Test("duplicate record rows sharing an id are read once")
    func duplicateRecordsCollapseOnRead() throws {
        let context = try IdentityGroupFixture.context()
        let older = IdentityGroupFixture.source(in: context, id: Self.identity, updatedAt: Self.epoch)
        let newer = IdentityGroupFixture.source(in: context, id: Self.identity,
                                                updatedAt: Self.epoch.addingTimeInterval(60))
        let rateID = WellKnownID.openingRate(forSource: Self.identity,
                                             effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        IdentityGroupFixture.rate(in: context, id: rateID, on: older, ringgit: 8_000,
                                  effectiveFrom: IncomeStoreTests.date(2025, 1, 1),
                                  updatedAt: Self.epoch)
        IdentityGroupFixture.rate(in: context, id: rateID, on: newer, ringgit: 8_000,
                                  effectiveFrom: IncomeStoreTests.date(2025, 1, 1),
                                  updatedAt: Self.epoch.addingTimeInterval(60))

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        #expect(resolved.records.count == 1)
    }

    @Test("two devices seeing the same rows in opposite orders resolve the same survivor")
    func resolutionIsOrderIndependent() throws {
        let deviceOne = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: deviceOne, id: Self.identity, name: "Main job",
                                    updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: deviceOne, id: Self.identity, name: "Day job",
                                    updatedAt: Self.epoch)

        let deviceTwo = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: deviceTwo, id: Self.identity, name: "Day job",
                                    updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: deviceTwo, id: Self.identity, name: "Main job",
                                    updatedAt: Self.epoch)

        // `updatedAt` ties and `id` is the thing they share, so the content hash is the
        // only tie-break left. If it were not there, each device would pick whichever row
        // its own fetch returned first and neither would ever converge.
        let one = ResolvedIncomeSource.resolving(try deviceOne.fetch(FetchDescriptor<IncomeSource>()))
        let two = ResolvedIncomeSource.resolving(try deviceTwo.fetch(FetchDescriptor<IncomeSource>()))
        #expect(one.first?.survivor.name == two.first?.survivor.name)
    }

    @Test("a group whose rows tie on stamp and content is not safe to collapse")
    func indistinguishableRowsRefuseToCollapse() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: Self.identity, updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: context, id: Self.identity, updatedAt: Self.epoch)

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        // Reads do not care — either row projects the same values. The sweep does: with no
        // total order, two devices can soft-delete different physical rows, both deletions
        // sync, and the union of them is no live source at all.
        #expect(resolved.isSafeToCollapse == false)
        #expect(resolved.group.count == 2)
    }

    @Test("a group with one row is trivially safe to collapse and merges nothing")
    func aLoneRowIsItsOwnGroup() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: Self.identity, updatedAt: Self.epoch)

        let resolved = try #require(
            ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).first)
        #expect(resolved.isSafeToCollapse)
        #expect(resolved.group.count == 1)
    }

    @Test("sources with different ids are never grouped, however alike")
    func lookalikesAreLeftAlone() throws {
        let context = try IdentityGroupFixture.context()
        IdentityGroupFixture.source(in: context, id: UUID(), name: "Rental", kind: .rental,
                                    updatedAt: Self.epoch)
        IdentityGroupFixture.source(in: context, id: UUID(), name: "Rental", kind: .rental,
                                    updatedAt: Self.epoch)

        // Merging these would be irreversible and would understate chargeable income,
        // which is the dangerous direction. Two rows stay two rows.
        #expect(ResolvedIncomeSource.resolving(try context.fetch(FetchDescriptor<IncomeSource>())).count == 2)
    }
}

@Suite("Income reconciliation") struct IncomeReconciliationTests {

    static let identity = WellKnownID.primaryEmployment
    static let rateIdentity = WellKnownID.openingRate(forSource: WellKnownID.primaryEmployment,
                                                      effectiveFrom: IncomeStoreTests.date(2025, 1, 1))

    /// Two rows for one identity, an hour apart, each with its own copy of the same rate —
    /// a second device's onboarding arriving over CloudKit.
    private static func storeWithADuplicatedMainJob(
        secondName: String = "Main job") async throws -> TaxStore {
        let store = try await StoreFixture.store()
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        await store.useClock { StoreFixture.epoch.addingTimeInterval(3_600) }
        try await store.insertDuplicateIncomeSourceForTesting(
            name: secondName, monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        return store
    }

    @Test("two IncomeSource rows sharing an id collapse onto the newest")
    func duplicateSourcesCollapse() async throws {
        let store = try await Self.storeWithADuplicatedMainJob(secondName: "Day job")
        let count = try await store.reconcileIncomeSources()

        #expect(count.sourcesMerged == 1)
        #expect(try await store.liveIncomeSourceRowCountForTesting(id: Self.identity) == 1)
        #expect(try await store.incomeSourceDrafts().first?.name == "Day job")
        // The figure the user sees does not move when the sweep runs. It was already right.
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("the survivor adopts deduction answers only the losing row carried")
    func survivorAdoptsAnswers() async throws {
        let store = try await StoreFixture.store()
        var older = IncomeSourceDraft(id: Self.identity, name: "Main job")
        older.deductsEPF = true
        older.deductsSOCSO = true
        try await store.save(older)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(3_600) }
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        _ = try await store.reconcileIncomeSources()

        let read = try #require(try await store.incomeSourceDrafts().first)
        // Answers the user gave on their other phone survive the merge. Discarding them
        // would silently unset deductions they had already confirmed.
        #expect(read.deductsEPF == true)
        #expect(read.deductsSOCSO == true)
    }

    @Test("records on a losing source row are re-pointed, not orphaned")
    func recordsFollowTheSurvivor() async throws {
        let store = try await StoreFixture.store()
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        // A bonus only the older row carries. Left hanging off a soft-deleted source it
        // would vanish from the user's own timeline.
        var bonus = IncomeRecordDraft(sourceID: Self.identity)
        bonus.shape = .oneOff
        bonus.amount = Money(ringgit: 5_000)
        bonus.effectiveFrom = IncomeStoreTests.date(2025, 3, 1)
        try await store.save(bonus)

        await store.useClock { StoreFixture.epoch.addingTimeInterval(3_600) }
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 9_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        _ = try await store.reconcileIncomeSources()

        let records = try await store.incomeRecordDrafts(forSource: Self.identity)
        #expect(records.contains { $0.amount == Money(ringgit: 5_000) })
        #expect(records.count == 2)
    }

    @Test("duplicate rate rows sharing an id collapse once their sources have merged")
    func duplicateRecordsCollapse() async throws {
        let store = try await Self.storeWithADuplicatedMainJob()
        let count = try await store.reconcileIncomeSources()

        // The record pass runs second because a record's group is only complete once
        // every row of its source's identity hangs off one surviving source.
        #expect(count.recordsMerged == 1)
        #expect(try await store.liveIncomeRecordRowCountForTesting(id: Self.rateIdentity) == 1)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("running income reconciliation twice changes nothing the second time")
    func sweepIsIdempotent() async throws {
        let store = try await Self.storeWithADuplicatedMainJob(secondName: "Day job")
        #expect(try await store.reconcileIncomeSources().changedAnything)

        let stamps = try await store.incomeSourceStampsForTesting(id: Self.identity)
        let second = try await store.reconcileIncomeSources()
        #expect(second == IncomeMergeCount())
        #expect(second.changedAnything == false)
        // Nothing written, not even a re-stamp: an idle phone's sweep must never outrank
        // a real edit made on another device under newest-write-wins.
        #expect(try await store.incomeSourceStampsForTesting(id: Self.identity) == stamps)
    }

    @Test("the income sweep does not stamp rows it did not actually change")
    func housekeepingIsNotStamped() async throws {
        let store = try await Self.storeWithADuplicatedMainJob(secondName: "Day job")
        let survivorStamp = StoreFixture.epoch.addingTimeInterval(3_600)
        await store.useClock { StoreFixture.epoch.addingTimeInterval(7_200) }
        _ = try await store.reconcileIncomeSources()

        // The survivor answered nothing new, so it is not stamped. Re-pointing a record
        // changes no field any resolver keys off, so that is not stamped either.
        #expect(try await store.incomeSourceDrafts().first?.updatedAt == survivorStamp)
        let records = try await store.incomeRecordDrafts(forSource: Self.identity)
        #expect(records.first?.updatedAt == survivorStamp)
    }

    @Test("two indistinguishable rows are left on disk rather than both being deleted")
    func tiedRowsAreLeftAlone() async throws {
        let store = try await StoreFixture.store()
        // Same identity, same stamp, same content: no total order exists between them.
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))
        try await store.insertDuplicateIncomeSourceForTesting(
            name: "Main job", monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeStoreTests.date(2025, 1, 1))

        #expect(try await store.reconcileIncomeSources() == IncomeMergeCount())
        // Two devices picking different physical rows would sync both deletions and leave
        // the user with no salary at all — worse than the duplicate. So both rows stay,
        // and the read keeps showing one source for as long as they do.
        #expect(try await store.liveIncomeSourceRowCountForTesting(id: Self.identity) == 2)
        #expect(try await store.incomeSourceDrafts().count == 1)
        #expect(try await store.derivedGrossIncome(for: 2025) == Money(ringgit: 96_000))
    }

    @Test("sources with different ids are left alone even when they share a name")
    func lookalikesAreNeverMerged() async throws {
        let store = try await StoreFixture.store()
        try await store.save(IncomeSourceDraft(name: "Rental", kind: .rental))
        try await store.save(IncomeSourceDraft(name: "Rental", kind: .rental))

        // Two flats let to two tenants. Merging them is irreversible and understates the
        // user's income; showing two rows overstates nothing and is honest.
        #expect(try await store.reconcileIncomeSources() == IncomeMergeCount())
        #expect(try await store.incomeSourceDrafts().count == 2)
    }

    @Test("the whole sweep reports what it merged in every category")
    func reconcileReportsIncome() async throws {
        let store = try await Self.storeWithADuplicatedMainJob(secondName: "Day job")
        try await store.saveYearFacts(YearFacts(), for: 2025)
        try await store.insertDuplicateYearForTesting(2025, grossIncomeOverride: nil)

        let outcome = try await store.reconcile()
        #expect(outcome.yearsMerged == 1)
        #expect(outcome.income == IncomeMergeCount(sourcesMerged: 1, recordsMerged: 1))
        #expect(outcome.changedAnything)
    }

    @Test("a sweep that only collapsed income still reports that something changed")
    func incomeAloneCountsAsAChange() async throws {
        let store = try await Self.storeWithADuplicatedMainJob(secondName: "Day job")
        let outcome = try await store.reconcile()
        // A caller reading `entryMerges` alone would skip the refresh after exactly the
        // sweep that moved the user's income onto one row.
        #expect(outcome.yearsMerged == 0)
        #expect(outcome.entryMerges.isEmpty)
        #expect(outcome.changedAnything)
    }
}
