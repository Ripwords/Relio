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
        let existing = try authoritativeSourceRow(identifier)

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
        // Never set outside a test — see `TaxStore.incomeRecordWriteFailure`.
        if let incomeRecordWriteFailure { throw incomeRecordWriteFailure }

        let stamp = now()
        let identifier = draft.id
        let sourceID = draft.sourceID

        let existing = try authoritativeRecordRow(identifier)
        // Deliberately not filtered to `deletedAt == nil`: a source that resolves but is
        // soft-deleted still attaches. That self-heals — the read path filters the record
        // out just as it would a deleted record, and it reappears correctly if the source
        // is revived, since `save(_ draft: IncomeSourceDraft)` clears `deletedAt`. Only a
        // source that does not exist at all is a problem.
        let source = try authoritativeSourceRow(sourceID)

        // Every record insists its source resolve, new or not. Nothing is written before
        // this check: an unresolvable `sourceID` here would otherwise save successfully
        // and silently vanish from every read, understating the year's income with no
        // signal to the caller.
        //
        // The update path is held to the same rule. Exempting it would set `row.source =
        // nil` on a record that previously had one — orphaning it, which is the identical
        // failure this guard exists to prevent, arrived at down the other branch.
        if source == nil {
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

    /// Seeds the user's main employment source and its opening monthly rate — once,
    /// however many times this is called, and on however many devices.
    ///
    /// The whole reason this exists rather than two `save` calls: the identity must be the
    /// store's knowledge. A caller minting a `UUID()` per screen is how the app came to
    /// write two "Main job" rows and double-count a year's income.
    ///
    /// Create-only, precisely:
    /// - An existing live source with this identity is left alone. `name` seeds a new row
    ///   and is ignored otherwise — the user may have renamed it, and a re-seed must not
    ///   rename it back or null the deduction answers they gave.
    /// - A soft-deleted one is revived, as `save(_: IncomeSourceDraft)` and `restoreEntry`
    ///   both do. Inserting a second row instead would manufacture the exact duplicate
    ///   this method exists to prevent.
    /// - An existing rate for this source and this calendar year is left alone, amount and
    ///   `effectiveFrom` both: the first answer given wins, and a re-seed is not a new
    ///   answer. A user who mistyped their salary corrects it on the Income screen, where
    ///   every other income edit happens; letting a stale second device overwrite would
    ///   undo that correction.
    ///
    /// A true no-op when there is nothing to write: nothing is re-stamped, per
    /// `softDeleteEntry`'s discipline.
    ///
    /// All-or-nothing, in one `save()`: a failure leaves no record-less "Main job" behind.
    ///
    /// - Returns: the source's identity, for symmetry with the other writes.
    @discardableResult
    public func seedPrimaryEmployment(name: String,
                                      monthlyRate: Money,
                                      effectiveFrom: Date) throws -> UUID {
        // Checked before any insert, not at the record write: the seam still reproduces
        // "the rate could not be written", and now proves nothing at all was.
        if let incomeRecordWriteFailure { throw incomeRecordWriteFailure }

        let identity = WellKnownID.primaryEmployment
        let stamp = now()
        var wroteAnything = false

        let source: IncomeSource
        if let existing = try authoritativeSourceRow(identity) {
            source = existing
            if source.deletedAt != nil {
                source.deletedAt = nil
                source.updatedAt = stamp
                wroteAnything = true
            }
        } else {
            source = IncomeSource(id: identity, name: name)
            source.updatedAt = stamp
            modelContext.insert(source)
            wroteAnything = true
        }

        let rateID = WellKnownID.openingRate(forSource: identity, effectiveFrom: effectiveFrom)
        if try authoritativeRecordRow(rateID) == nil {
            let rate = IncomeRecord(id: rateID)
            rate.shape = .recurring
            rate.amount = monthlyRate
            rate.effectiveFrom = effectiveFrom
            rate.updatedAt = stamp
            rate.source = source
            modelContext.insert(rate)
            wroteAnything = true
        }

        if wroteAnything { try modelContext.save() }
        return identity
    }

    /// Deletes **every** live row sharing this identity, not an arbitrary one of them.
    ///
    /// Deleting one of two leaves the other live, and the read then resolves to it: the
    /// user deletes their job and watches it come back. A delete has to converge to the
    /// same end state however many rows CloudKit delivered.
    ///
    /// Idempotent, like every other delete here: deleting an absent or already-deleted id
    /// is a no-op, and an already-deleted row is not re-stamped — a replayed delete must
    /// not outrank a genuine concurrent edit under newest-write-wins.
    public func softDeleteIncomeSource(id: UUID) throws {
        let live = try modelContext.fetch(FetchDescriptor<IncomeSource>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil }))
        guard !live.isEmpty else { return }
        let stamp = now()
        for row in live {
            row.deletedAt = stamp
            row.updatedAt = stamp
        }
        try modelContext.save()
    }

    /// Same rule as `softDeleteIncomeSource`: a duplicated rate left half-deleted still
    /// pays out on the next read.
    public func softDeleteIncomeRecord(id: UUID) throws {
        let live = try modelContext.fetch(FetchDescriptor<IncomeRecord>(
            predicate: #Predicate { $0.id == id && $0.deletedAt == nil }))
        guard !live.isEmpty else { return }
        let stamp = now()
        for row in live {
            row.deletedAt = stamp
            row.updatedAt = stamp
        }
        try modelContext.save()
    }

    // MARK: - Reads

    /// One draft per identity, not per row. Two rows CloudKit delivered for one source are
    /// one source here, before any sweep has run and whether or not one ever does.
    public func incomeSourceDrafts() throws -> [IncomeSourceDraft] {
        try resolvedSources().map(draft(of:))
    }

    public func incomeRecordDrafts(forSource sourceID: UUID) throws -> [IncomeRecordDraft] {
        guard let resolved = try resolvedSources().first(where: { $0.id == sourceID }) else {
            return []
        }
        return recordDrafts(of: resolved)
    }

    /// The value types the derivation works on. This is the whole bridge between SwiftData
    /// and the pure function — there is no arithmetic here.
    public func incomeSnapshots() throws -> [IncomeSourceSnapshot] {
        try resolvedSources().map(snapshot(of:))
    }

    public func derivedGrossIncome(for year: Int) throws -> Money {
        IncomeDerivation.annualGross(for: year, from: try incomeSnapshots())
    }

    /// Everything the Income screen needs about one year, from a single fetch.
    ///
    /// The screen used to take the subtotals, the sources and each source's records in
    /// separate actor calls and join them by id. A soft-delete landing between two of
    /// those reads dropped a row from the list while its amount still counted toward the
    /// total — the screen then showed a derivation that visibly did not add up. Here the
    /// subtotals, the sources' own fields, the records and the known/unknown answer all
    /// come off one `liveSources()` fetch, so they cannot describe different stores.
    public func incomeSummary(for year: Int) throws -> IncomeYearSummary {
        let sources = try resolvedSources()
        let snapshots = sources.map(snapshot(of:))

        // `knownAnnualGross`, not the sum of the subtotals: the same call the projection
        // makes, so the screen and the engine cannot disagree about whether this year is
        // known at all. A year the timeline never reaches is `nil` here and RM 0.00 there.
        let known = IncomeDerivation.knownAnnualGross(for: year, from: snapshots)

        // Keyed on resolved identities, so a source CloudKit delivered twice yields one
        // row. Keying on physical rows kept only one of them here while
        // `IncomeDerivation.totals` returned a subtotal per snapshot, and the `compactMap`
        // below then emitted two rows carrying the same source and the same records with
        // different subtotals.
        var byID: [UUID: ResolvedIncomeSource] = [:]
        for source in sources { byID[source.id] = source }

        // Ordered by `totals`, which sorts by name then id — stable between launches and
        // between devices.
        let rows = IncomeDerivation.totals(for: year, from: snapshots).compactMap {
            total -> IncomeYearRow? in
            guard let source = byID[total.sourceID] else { return nil }
            return IncomeYearRow(source: draft(of: source), total: total.total,
                                 records: recordDrafts(of: source))
        }
        return IncomeYearSummary(rows: rows, knownTotal: known)
    }

    // MARK: - Row conversions

    private func draft(of resolved: ResolvedIncomeSource) -> IncomeSourceDraft {
        var draft = IncomeSourceDraft(id: resolved.id,
                                      name: resolved.survivor.name,
                                      kind: resolved.survivor.kind,
                                      deductsEPF: resolved.deductsEPF,
                                      deductsSOCSO: resolved.deductsSOCSO,
                                      endedOn: resolved.endedOn)
        draft.updatedAt = resolved.survivor.updatedAt
        return draft
    }

    private func recordDrafts(of resolved: ResolvedIncomeSource) -> [IncomeRecordDraft] {
        resolved.records.map { row in
            var draft = IncomeRecordDraft(id: row.id, sourceID: resolved.id, shape: row.shape,
                                          amount: row.amount,
                                          effectiveFrom: row.effectiveFrom, note: row.note)
            draft.updatedAt = row.updatedAt
            return draft
        }
    }

    private func snapshot(of resolved: ResolvedIncomeSource) -> IncomeSourceSnapshot {
        IncomeSourceSnapshot(
            id: resolved.id, name: resolved.survivor.name, kind: resolved.survivor.kind,
            endedOn: resolved.endedOn,
            records: resolved.records.map {
                IncomeRecordSnapshot(id: $0.id, shape: $0.shape,
                                     amount: $0.amount, effectiveFrom: $0.effectiveFrom)
            })
    }

    // MARK: - Internals

    /// Every live row, unresolved. Only `resolvedSources()` and the sweep want this — a
    /// caller working from physical rows is a caller that will double-count.
    func liveSourceRows() throws -> [IncomeSource] {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    /// Every live record row across every source. Only the sweep's record pass wants this:
    /// a record's identity is scoped to nothing, so the group is global.
    func liveRecordRows() throws -> [IncomeRecord] {
        try modelContext
            .fetch(FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.deletedAt == nil }))
    }

    /// One resolved source per identity, ordered by `id.uuidString` as the raw fetch used
    /// to be. The store's only view of income: reads project these, writes target their
    /// survivors, and the sweep persists them.
    func resolvedSources() throws -> [ResolvedIncomeSource] {
        ResolvedIncomeSource.resolving(try liveSourceRows())
    }

    /// The row a write for this identity must land on: the one the read path resolves to.
    ///
    /// Not `.first`. Two rows can share an id, and a write to the other one is ranked
    /// below whatever a device with a faster clock last wrote — so the user's edit saves
    /// successfully and is invisible on the very next read.
    ///
    /// A live row always outranks a soft-deleted one, and a write to a wholly deleted
    /// identity revives its authoritative row rather than adding a second.
    private func authoritativeSourceRow(_ id: UUID) throws -> IncomeSource? {
        let rows = try modelContext.fetch(
            FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id }))
        let live = rows.filter { $0.deletedAt == nil }
        return ResolvedIncomeSource.resolving(live.isEmpty ? rows : live).first?.survivor
    }

    private func authoritativeRecordRow(_ id: UUID) throws -> IncomeRecord? {
        let rows = try modelContext.fetch(
            FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.id == id }))
        let live = rows.filter { $0.deletedAt == nil }
        return ResolvedIncomeSource.authoritative(among: live.isEmpty ? rows : live)
    }
}

// MARK: - Test-only seams

extension TaxStore {
    func incomeSourceUpdatedAtForTesting(_ id: UUID) throws -> Date? {
        try modelContext
            .fetch(FetchDescriptor<IncomeSource>(predicate: #Predicate { $0.id == id }))
            .first?.updatedAt
    }

    /// The collision only two devices syncing can produce: a second physical row asserting
    /// an existing identity, carrying its own row for the same rate identity. Nothing in
    /// the app can write one `id` twice, and CloudKit cannot be asked to prevent it.
    func insertDuplicateIncomeSourceForTesting(id: UUID = WellKnownID.primaryEmployment,
                                               name: String,
                                               monthlyRate: Money,
                                               effectiveFrom: Date) throws {
        let stamp = now()
        let source = IncomeSource(id: id, name: name)
        source.updatedAt = stamp
        modelContext.insert(source)

        let rate = IncomeRecord(
            id: WellKnownID.openingRate(forSource: id, effectiveFrom: effectiveFrom))
        rate.shape = .recurring
        rate.amount = monthlyRate
        rate.effectiveFrom = effectiveFrom
        rate.updatedAt = stamp
        rate.source = source
        modelContext.insert(rate)

        try modelContext.save()
    }

    func liveIncomeSourceRowCountForTesting(id: UUID) throws -> Int {
        try liveSourceRows().filter { $0.id == id }.count
    }

    func liveIncomeRecordRowCountForTesting(id: UUID) throws -> Int {
        try modelContext
            .fetch(FetchDescriptor<IncomeRecord>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { $0.id == id }
            .count
    }

    /// Every `IncomeSource` row's `updatedAt` for one identity, live or soft-deleted, keyed
    /// by `persistentModelID` — so a test can prove the sweep left a row it did not change
    /// untouched. `id` cannot key this dictionary: it is the thing they share.
    func incomeSourceStampsForTesting(id: UUID) throws -> [PersistentIdentifier: Date] {
        let rows = try modelContext
            .fetch(FetchDescriptor<IncomeSource>())
            .filter { $0.id == id }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.persistentModelID, $0.updatedAt) })
    }
}
