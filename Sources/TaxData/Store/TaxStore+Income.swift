import Foundation
import SwiftData
import TaxKit

/// Writing a record against a source that does not exist would silently drop income:
/// the row would save, return a valid `UUID`, and then be invisible to
/// `incomeRecordDrafts(forSource:)` and to the derivation — understating chargeable
/// income with no signal to the caller. Spec §6.
public enum IncomeStoreError: Error, Equatable {
    case unknownIncomeSource(UUID)
}

public struct IncomeSourceDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    /// `nil` is "not asked yet". Never default this to `false`.
    public var deductsEPF: Bool?
    public var deductsSOCSO: Bool?
    /// The last day this source paid, inclusive.
    public var endedOn: Date?
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), name: String = "", kind: IncomeKind = .employment,
                deductsEPF: Bool? = nil, deductsSOCSO: Bool? = nil, endedOn: Date? = nil) {
        self.id = id
        self.name = name
        self.kind = kind
        self.deductsEPF = deductsEPF
        self.deductsSOCSO = deductsSOCSO
        self.endedOn = endedOn
        self.updatedAt = .distantPast
    }
}

public struct IncomeRecordDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var sourceID: UUID
    public var shape: IncomeShape
    public var amount: Money
    public var effectiveFrom: Date
    public var note: String
    public internal(set) var updatedAt: Date

    public init(id: UUID = UUID(), sourceID: UUID, shape: IncomeShape = .recurring,
                amount: Money = .zero, effectiveFrom: Date = .distantPast, note: String = "") {
        self.id = id
        self.sourceID = sourceID
        self.shape = shape
        self.amount = amount
        self.effectiveFrom = effectiveFrom
        self.note = note
        self.updatedAt = .distantPast
    }
}

extension TaxStore {

    @discardableResult
    public func save(_ draft: IncomeSourceDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? IncomeSource(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.name = draft.name
        row.kind = draft.kind
        row.deductsEPF = draft.deductsEPF
        row.deductsSOCSO = draft.deductsSOCSO
        row.endedOn = draft.endedOn
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    @discardableResult
    public func save(_ draft: IncomeRecordDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let sourceID = draft.sourceID

        let existing = try modelContext.fetch(
            FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.id == identifier })
        ).first
        // Deliberately not filtered to `deletedAt == nil`: a source that resolves but is
        // soft-deleted still attaches. That self-heals — `liveSources()` filters the
        // record out just as it would a deleted record, and it reappears correctly if
        // the source is revived, since `save(_ draft: IncomeSourceDraft)` clears
        // `deletedAt`. Only a source that does not exist at all is a problem.
        let source = try modelContext.fetch(
            FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == sourceID })
        ).first

        // Only a brand-new record insists its source resolve. Nothing is written before
        // this check: an unresolvable `sourceID` here would otherwise save successfully
        // and silently vanish from every read, understating the year's income with no
        // signal to the caller.
        if existing == nil && source == nil {
            throw IncomeStoreError.unknownIncomeSource(sourceID)
        }

        let row = existing ?? IncomeRecord(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.shape = draft.shape
        row.amount = draft.amount
        row.effectiveFrom = draft.effectiveFrom
        row.note = draft.note
        row.source = source
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    /// Idempotent, like every other delete here: deleting an absent or already-deleted id
    /// is a no-op, and an already-deleted row is not re-stamped — a replayed delete must
    /// not outrank a genuine concurrent edit under newest-write-wins.
    public func softDeleteIncomeSource(id: UUID) throws {
        let descriptor = FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first, row.deletedAt == nil else { return }
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
        try modelContext.save()
    }

    public func softDeleteIncomeRecord(id: UUID) throws {
        let descriptor = FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first, row.deletedAt == nil else { return }
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
        try modelContext.save()
    }

    // MARK: - Reads

    public func incomeSourceDrafts() throws -> [IncomeSourceDraft] {
        try liveSources().map { row in
            var draft = IncomeSourceDraft(id: row.id, name: row.name, kind: row.kind,
                                          deductsEPF: row.deductsEPF,
                                          deductsSOCSO: row.deductsSOCSO,
                                          endedOn: row.endedOn)
            draft.updatedAt = row.updatedAt
            return draft
        }
    }

    public func incomeRecordDrafts(forSource sourceID: UUID) throws -> [IncomeRecordDraft] {
        guard let source = try liveSources().first(where: { $0.id == sourceID }) else { return [] }
        return source.liveRecords
            .sorted { left, right in
                if left.effectiveFrom != right.effectiveFrom {
                    return left.effectiveFrom < right.effectiveFrom
                }
                return left.id.uuidString < right.id.uuidString
            }
            .map { row in
                var draft = IncomeRecordDraft(id: row.id, sourceID: sourceID, shape: row.shape,
                                              amount: row.amount,
                                              effectiveFrom: row.effectiveFrom, note: row.note)
                draft.updatedAt = row.updatedAt
                return draft
            }
    }

    /// The value types the derivation works on. This is the whole bridge between SwiftData
    /// and the pure function — there is no arithmetic here.
    public func incomeSnapshots() throws -> [IncomeSourceSnapshot] {
        try liveSources().map { row in
            IncomeSourceSnapshot(
                id: row.id, name: row.name, kind: row.kind, endedOn: row.endedOn,
                records: row.liveRecords.map {
                    IncomeRecordSnapshot(id: $0.id, shape: $0.shape,
                                         amount: $0.amount, effectiveFrom: $0.effectiveFrom)
                })
        }
    }

    public func derivedGrossIncome(for year: Int) throws -> Money {
        IncomeDerivation.annualGross(for: year, from: try incomeSnapshots())
    }

    public func incomeTotals(for year: Int) throws -> [IncomeSourceTotal] {
        IncomeDerivation.totals(for: year, from: try incomeSnapshots())
    }

    private func liveSources() throws -> [IncomeSource] {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.deletedAt == nil }))
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
}

// MARK: - Test-only seams

extension TaxStore {
    func incomeSourceUpdatedAtForTesting(_ id: UUID) throws -> Date? {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id }))
            .first?.updatedAt
    }
}
