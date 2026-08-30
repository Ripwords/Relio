import Foundation
import SwiftData
import TaxKit

/// A row two devices can each hand us a copy of, ordered by when it was last written.
///
/// Read-only and adds no stored property, so `SchemaV1` is untouched: `Schema(_:).entities`
/// reports attributes and relationships, and a protocol is neither.
protocol StampedRow: AnyObject {
    var updatedAt: Date { get }
}

extension IncomeSource: StampedRow {}
extension IncomeRecord: StampedRow {}

/// One identity group of live `IncomeSource` rows, merged in memory.
///
/// The single definition of what merging income means. `TaxStore+Income`'s reads project
/// it; `reconcileIncomeSources()` persists it. Two copies of this policy is exactly the
/// drift `resolvedPreferencesRow`'s doc comment was written about — and here the two
/// copies would disagree about the user's declared income, not about a settings row.
///
/// Only a shared `id` groups. Two rows asserting the same identity can only be the same
/// logical row; two sources that merely look alike are never merged, because that merge is
/// irreversible (`IncomeSource` has no `mergedInto`, and `SchemaV1` is frozen) and a wrong
/// one *understates* chargeable income.
///
/// Holds `@Model` references and is therefore deliberately **not** `Sendable`. It never
/// leaves the actor: every public return value is still a value type.
struct ResolvedIncomeSource {

    /// The row the rest of the store treats as authoritative for this identity: newest
    /// `updatedAt`, then highest content key. Reads project it; writes target it.
    let survivor: IncomeSource

    /// Every live row in the group, `survivor` first, in the same total order.
    let group: [IncomeSource]

    /// Gap-filled across the group — `nil` means "not asked yet" for these two, and no UI
    /// writes them back to `nil`, so adopting a losing row's answer cannot lose one while
    /// never overwriting means the newest device's answer still wins. The same rule as
    /// `Reconciliation.fillGaps`.
    let deductsEPF: Bool?
    let deductsSOCSO: Bool?

    /// The survivor's own value, **not** gap-filled, unlike the two answers above.
    ///
    /// `nil` here is a real answer — "still paying" — and not only "not asked yet":
    /// `IncomeRecordEditorViewModel` writes `endedOn = nil` when the user clears the end
    /// date, and the Income screen offers reopening a source. Gap-filling would let a
    /// stale row's end date silently re-end a job the user has just reopened, which
    /// understates the year. `endedOn` therefore follows newest-write-wins, as `name` and
    /// `kind` do.
    let endedOn: Date?

    /// The union of every group member's live records, one per record `id`. Unioning is
    /// what makes the read agree with the post-sweep state: taking only the survivor's
    /// records would show one figure now and a different one after the sweep re-points the
    /// losers'. Ordered by `effectiveFrom` then id, the display order the timeline uses.
    let records: [IncomeRecord]

    /// `false` when two rows in the group are indistinguishable — same `id`, same
    /// `updatedAt`, same content key.
    ///
    /// Reads do not care: any of them projects the same values. **The sweep must.** With
    /// no total order, two devices can pick different physical rows to soft-delete, both
    /// deletions sync, and the union of them is no live source at all. That is a worse
    /// failure than the duplicate, so a tied group is left on disk and resolved on read
    /// forever.
    let isSafeToCollapse: Bool

    var id: UUID { survivor.id }
}

extension ResolvedIncomeSource {

    /// Groups live rows by `id` and merges each group, ordered by `id.uuidString`.
    ///
    /// Pure: reads rows, writes nothing, reads no clock. That is what lets the read path
    /// and the sweep share it without either being able to observe the other.
    static func resolving(_ live: [IncomeSource]) -> [ResolvedIncomeSource] {
        var resolved: [ResolvedIncomeSource] = []
        for (_, group) in Dictionary(grouping: live, by: \.id) {
            let ordered = group
                .map { (row: $0, content: contentKey(of: $0)) }
                .sorted(by: precedes)
            guard let survivor = ordered.first?.row else { continue }

            var deductsEPF: Bool?
            var deductsSOCSO: Bool?
            for candidate in ordered.map(\.row) {
                deductsEPF = deductsEPF ?? candidate.deductsEPF
                deductsSOCSO = deductsSOCSO ?? candidate.deductsSOCSO
            }

            resolved.append(
                ResolvedIncomeSource(survivor: survivor,
                                     group: ordered.map(\.row),
                                     deductsEPF: deductsEPF,
                                     deductsSOCSO: deductsSOCSO,
                                     endedOn: survivor.endedOn,
                                     records: unionedRecords(of: ordered.map(\.row)),
                                     isSafeToCollapse: !hasATie(ordered)))
        }
        return resolved.sorted { $0.id.uuidString < $1.id.uuidString }
    }

    /// The record row a write must land on, under the same total order sources use.
    ///
    /// Records need only the winner, not a merged group: unlike a source they carry no
    /// three-valued answers to gap-fill and no relationship to union.
    static func authoritative(among rows: [IncomeRecord]) -> IncomeRecord? {
        rows.map { (row: $0, content: contentKey(of: $0)) }.sorted(by: precedes).first?.row
    }

    /// One row per record `id`, resolved by the same total order the sources use, so a
    /// duplicate rate delivered twice contributes once.
    private static func unionedRecords(of sources: [IncomeSource]) -> [IncomeRecord] {
        var byID: [UUID: (row: IncomeRecord, content: String)] = [:]
        for source in sources {
            for record in source.liveRecords {
                let candidate = (row: record, content: contentKey(of: record))
                if let held = byID[record.id], !precedes(candidate, held) { continue }
                byID[record.id] = candidate
            }
        }
        return byID.values.map(\.row).sorted { left, right in
            if left.effectiveFrom != right.effectiveFrom {
                return left.effectiveFrom < right.effectiveFrom
            }
            return left.id.uuidString < right.id.uuidString
        }
    }

    static func hasATie<Row: StampedRow>(_ ordered: [(row: Row, content: String)]) -> Bool {
        // Adjacent is enough: the sequence is already sorted on exactly the pair being
        // compared, so any two equal elements are neighbours.
        zip(ordered, ordered.dropFirst()).contains { left, right in
            left.row.updatedAt == right.row.updatedAt && left.content == right.content
        }
    }

    static func precedes<Row: StampedRow>(_ lhs: (row: Row, content: String),
                                          _ rhs: (row: Row, content: String)) -> Bool {
        if lhs.row.updatedAt != rhs.row.updatedAt { return lhs.row.updatedAt > rhs.row.updatedAt }
        // `TaxStore.isNewer` breaks its tie on `id.uuidString`, which degenerates here:
        // the id is the thing these rows share. Content is the only tie-break left.
        return lhs.content > rhs.content
    }

    static func contentKey(of row: IncomeSource) -> String {
        DedupeKey.incomeSourceContent(name: row.name, kindRaw: row.kindRaw,
                                      deductsEPF: row.deductsEPF,
                                      deductsSOCSO: row.deductsSOCSO,
                                      endedOn: row.endedOn)
    }

    static func contentKey(of row: IncomeRecord) -> String {
        DedupeKey.incomeRecordContent(shapeRaw: row.shapeRaw, amountSen: row.amountSen,
                                      effectiveFrom: row.effectiveFrom, note: row.note)
    }
}

/// What one income sweep collapsed.
///
/// Counts, not `MergeReport`s. A `MergeReport` carries a `dedupeKey`, and there is no
/// dedupe key here — the group *is* an id. Reporting a fabricated one would tell a reader
/// this pass works like the entry pass, which is the misreading this design most needs to
/// prevent. `IncomeSource` also has no `mergedInto` column, so unlike an entry merge this
/// one is not individually auditable; only the certainty of the key makes that acceptable.
public struct IncomeMergeCount: Hashable, Sendable {
    public var sourcesMerged: Int
    public var recordsMerged: Int

    public var changedAnything: Bool { sourcesMerged > 0 || recordsMerged > 0 }

    public init(sourcesMerged: Int = 0, recordsMerged: Int = 0) {
        self.sourcesMerged = sourcesMerged
        self.recordsMerged = recordsMerged
    }
}

extension TaxStore {

    /// Collapses live `IncomeSource` rows that share an `id`, and the duplicate
    /// `IncomeRecord` rows that come with them.
    ///
    /// Housekeeping, not the fix. The reads already resolve these groups, so the user's
    /// figure is correct before this runs and does not move when it does. What this buys
    /// is that the duplicate rows do not accumulate forever.
    ///
    /// One method, not two: a caller cannot correctly reconcile records without first
    /// re-pointing them onto a surviving source, so exposing the two stages separately
    /// would make every caller re-derive the ordering. The record pass runs second for the
    /// reason `reconcile()` runs years before entries — a record's group is only complete
    /// once every row of its source's identity hangs off one source.
    ///
    /// Only rows sharing an `id` are touched, and only when the group has a total order —
    /// see `ResolvedIncomeSource.isSafeToCollapse`.
    ///
    /// Idempotent: a second run reports zero and writes nothing. Housekeeping is never
    /// stamped, and a re-point changes no field any resolver keys off; stamping it would
    /// let an idle phone's sweep outrank a real edit on another device under
    /// newest-write-wins.
    @discardableResult
    public func reconcileIncomeSources() throws -> IncomeMergeCount {
        var count = IncomeMergeCount()
        let stamp = now()

        for resolved in try resolvedSources()
        where resolved.group.count > 1 && resolved.isSafeToCollapse {
            let survivor = resolved.survivor
            var survivorGainedAnAnswer = false
            if survivor.deductsEPF == nil, let adopted = resolved.deductsEPF {
                survivor.deductsEPF = adopted
                survivorGainedAnAnswer = true
            }
            if survivor.deductsSOCSO == nil, let adopted = resolved.deductsSOCSO {
                survivor.deductsSOCSO = adopted
                survivorGainedAnAnswer = true
            }

            for loser in resolved.group.dropFirst() {
                // Snapshotted into an array first: `record.source = survivor` mutates the
                // inverse side of the very relationship being walked. Soft-deleted records
                // travel too, or restoring one later would revive it onto a dead source.
                for record in Array(loser.records ?? []) {
                    record.source = survivor
                }
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                count.sourcesMerged += 1
            }
            // Same rule as `reconcileYears`: the survivor is stamped only when it actually
            // adopted an answer it did not have.
            if survivorGainedAnAnswer { survivor.updatedAt = stamp }
        }

        for (_, group) in Dictionary(grouping: try liveRecordRows(), by: \.id)
        where group.count > 1 {
            let ordered = group
                .map { (row: $0, content: ResolvedIncomeSource.contentKey(of: $0)) }
                .sorted(by: ResolvedIncomeSource.precedes)
            guard !ResolvedIncomeSource.hasATie(ordered) else { continue }
            for loser in ordered.dropFirst().map(\.row) {
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                count.recordsMerged += 1
            }
        }

        if count.changedAnything { try modelContext.save() }
        return count
    }
}
