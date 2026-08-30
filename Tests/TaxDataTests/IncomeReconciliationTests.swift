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
