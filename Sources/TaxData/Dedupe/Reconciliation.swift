import Foundation
import SwiftData
import TaxKit

/// One group of duplicates that was collapsed.
public struct MergeReport: Hashable, Sendable {
    public var dedupeKey: String
    public var survivorID: UUID
    /// Sorted, so two devices produce identical reports for identical data.
    public var mergedIDs: [UUID]
}

/// Everything one sweep changed.
///
/// Both halves are reported because either can be non-empty on its own: a year collapse
/// writes to disk (rows soft-deleted, entries re-pointed) while producing no
/// `MergeReport` at all. A caller reading the entry reports alone and treating an empty
/// array as "nothing changed" would skip a refresh after exactly the sweep that moved
/// the user's entries between year rows.
public struct ReconciliationOutcome: Hashable, Sendable {
    /// Duplicate `TaxYear` rows merged away.
    public var yearsMerged: Int
    /// One report per collapsed group of duplicate entries.
    public var entryMerges: [MergeReport]

    public var changedAnything: Bool { yearsMerged > 0 || !entryMerges.isEmpty }

    public init(yearsMerged: Int, entryMerges: [MergeReport]) {
        self.yearsMerged = yearsMerged
        self.entryMerges = entryMerges
    }
}

extension TaxStore {

    /// Collapses duplicate entries. Runs on every sync-complete event.
    ///
    /// Deterministic by construction: the survivor is the row with the newest
    /// `updatedAt`, ties broken on `id.uuidString`. Nothing coordinates the devices, so
    /// the survivor has to be a pure function of the rows — if two devices disagreed,
    /// each would resurrect the other's soft-deleted loser and the duplicate would
    /// survive forever.
    ///
    /// Idempotent: a second run over already-merged data reports nothing and writes
    /// nothing. It has to be, or every sync would churn `updatedAt` and look like a
    /// change to every other device.
    @discardableResult
    public func reconcile() throws -> ReconciliationOutcome {
        // Years first: now that `year` is part of the dedupe key, an entry re-pointed at
        // the surviving year must be settled before the entry pass computes any key that
        // would depend on it, or the two passes could disagree about which year an entry
        // belongs to within the same sweep.
        //
        // The count is returned rather than discarded: a year collapse writes to disk
        // without producing a single `MergeReport`, so a caller reading only the reports
        // would conclude the sweep changed nothing.
        let yearsMerged = try reconcileYears()

        let live = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))

        // An empty key means the row never went through `save`, which should be
        // impossible. Grouping all such rows together would merge unrelated entries, so
        // they are skipped — the safe direction.
        let groups = Dictionary(grouping: live.filter { !$0.dedupeKey.isEmpty },
                                by: \.dedupeKey)

        var reports: [MergeReport] = []
        let stamp = now()

        for key in groups.keys.sorted() {
            guard let group = groups[key], group.count > 1 else { continue }

            let ordered = group.sorted { left, right in
                if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                return left.id.uuidString > right.id.uuidString
            }
            guard let survivor = ordered.first else { continue }
            let losers = Array(ordered.dropFirst())

            var documents = survivor.documents ?? []
            for loser in losers {
                for document in loser.documents ?? [] where !documents.contains(where: { $0.id == document.id }) {
                    documents.append(document)
                }
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                loser.mergedInto = survivor.id
            }
            // Dropping a loser's documents would turn a complete claim into one failing
            // its requirement check. The merge must never destroy evidence.
            survivor.documents = documents.sorted { $0.id.uuidString < $1.id.uuidString }
            survivor.updatedAt = stamp
            // needsDocument is cached and only recomputed on a write to the row; without
            // this the exact case the union exists for — the loser carried the required
            // document, the survivor did not — would leave the survivor still flagged as
            // missing it until the user next edits the entry by hand.
            refreshDerivedFields(on: survivor)

            reports.append(MergeReport(dedupeKey: key,
                                       survivorID: survivor.id,
                                       mergedIDs: losers.map(\.id).sorted { $0.uuidString < $1.uuidString }))
        }

        if !reports.isEmpty { try modelContext.save() }
        return ReconciliationOutcome(yearsMerged: yearsMerged, entryMerges: reports)
    }

    /// Reverses one merge, bringing a soft-deleted loser back as its own entry.
    ///
    /// Known limitation: restoring a loser this way does not change its `dedupeKey`, so
    /// its group is a duplicate again and the next `reconcile()` will re-merge it.
    /// Resolving that needs a "the user decided these are different" marker, which
    /// belongs with the merge UI in a later plan (there is no merge screen yet). Until
    /// then, `unmerge` is only safe to call when the sweep will not run again before the
    /// user edits one of the two rows.
    ///
    /// Deliberately does NOT stamp `updatedAt`: doing so would make the restored row
    /// newer than the survivor it lost to, so the next sweep would not merely re-merge
    /// it — it would invert which row survives, and the user would watch a *different*
    /// entry disappear each time. Leaving the original stamp in place means a re-merge
    /// resolves the same way it did before, which is the stable (if still imperfect)
    /// limitation documented above rather than a destructive surprise.
    public func unmerge(entryID: UUID) throws {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == entryID })
        guard let row = try modelContext.fetch(descriptor).first, row.mergedInto != nil else { return }
        row.mergedInto = nil
        row.deletedAt = nil
        try modelContext.save()
    }

    public func mergedInto(entryID: UUID) throws -> UUID? {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == entryID })
        return try modelContext.fetch(descriptor).first?.mergedInto
    }

    /// Collapses duplicate `TaxYear` rows, returning how many were merged away.
    ///
    /// Two devices first launching offline each create their own row for the same year.
    /// Task 4 made the *selection* deterministic so both devices at least agree; this
    /// removes the duplicate.
    ///
    /// Facts merge by filling gaps and never by overwriting: `nil` means "not answered
    /// yet" everywhere in this app, so adopting a loser's value where the survivor has
    /// none cannot lose an answer, while refusing to overwrite means the newer device's
    /// answer always wins. Discarding the loser's facts would silently throw away income
    /// the user entered on their other phone.
    @discardableResult
    public func reconcileYears() throws -> Int {
        let live = try modelContext.fetch(
            FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))

        var merged = 0
        let stamp = now()

        for (_, group) in Dictionary(grouping: live, by: \.year) where group.count > 1 {
            // The same total order `fetchOrCreateYear` and `yearFacts` use, not a second
            // copy of it: if this drifted from `TaxStore.isNewer` the sweep could
            // soft-delete the row the rest of the store still considers authoritative.
            let ordered = group.sorted(by: TaxStore.isNewer)
            guard let survivor = ordered.first else { continue }

            var survivorGainedAFact = false
            for loser in ordered.dropFirst() {
                survivorGainedAFact = Self.fillGaps(on: survivor, from: loser) || survivorGainedAFact
                // Re-point rather than orphan: an entry left hanging off a soft-deleted
                // year would vanish from the user's own records. Snapshotted into an
                // array first: `entry.taxYear = survivor` mutates the inverse side of the
                // relationship we are iterating, and mutating a collection while walking
                // it is undefined.
                //
                // Deliberately NOT stamped: re-pointing changes no field any resolver
                // keys off — not the dedupe key, not a fact, not the amount — so the
                // stamp would say "this device edited this entry" about housekeeping
                // that edited nothing. Under newest-write-wins that lets a sweep on an
                // idle phone outrank a genuine edit made on another device, which is the
                // exact failure `softDeleteEntry`'s no-op guard was hardened against.
                for entry in Array(loser.entries ?? []) {
                    entry.taxYear = survivor
                }
                loser.deletedAt = stamp
                loser.updatedAt = stamp
                merged += 1
            }
            // Same rule for the survivor: stamped only when it actually adopted a fact.
            // A survivor that already answered everything the loser knew is unchanged,
            // and a re-stamp there would beat a real answer typed on another device.
            if survivorGainedAFact { survivor.updatedAt = stamp }
        }

        if merged > 0 { try modelContext.save() }
        return merged
    }

    /// Copies every fact the survivor has not answered from the loser. Never overwrites.
    ///
    /// Returns whether it actually copied anything, so the caller can stamp the survivor
    /// only when the survivor really changed. A gap the loser cannot fill either — both
    /// `nil` — is not a change, so it does not count.
    @discardableResult
    private static func fillGaps(on survivor: TaxYear, from loser: TaxYear) -> Bool {
        var copied = false
        func fill<Value>(_ keyPath: ReferenceWritableKeyPath<TaxYear, Value?>) {
            guard survivor[keyPath: keyPath] == nil,
                  let value = loser[keyPath: keyPath] else { return }
            survivor[keyPath: keyPath] = value
            copied = true
        }
        fill(\.grossIncomeSen)
        fill(\.epfSen)
        fill(\.socsoSen)
        fill(\.maritalStatusRaw)
        fill(\.spouseHasIncome)
        fill(\.assessmentTypeRaw)
        fill(\.employmentTypeRaw)
        fill(\.genderRaw)
        fill(\.propertyPriceSen)
        fill(\.selfIsDisabled)
        fill(\.spouseIsDisabled)
        return copied
    }
}

// MARK: - Test-only seams

extension TaxStore {

    /// Creates the second live `TaxYear` row for a year that only two devices syncing
    /// can otherwise produce.
    func insertDuplicateYearForTesting(_ year: Int, grossIncome: Money?) throws {
        let row = TaxYear(year: year)
        row.grossIncome = grossIncome
        row.updatedAt = now()
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Every `TaxYear` row's `updatedAt` for a year, live or soft-deleted, keyed by id —
    /// so a test can prove the sweep left a row it did not change untouched. Only the
    /// tests call this.
    func yearUpdatedAtsForTesting(year: Int) throws -> [UUID: Date] {
        let rows = try modelContext
            .fetch(FetchDescriptor<TaxYear>())
            .filter { $0.year == year }
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.updatedAt) })
    }

    func liveYearRowCount(_ year: Int) throws -> Int {
        try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))
            .filter { $0.year == year }
            .count
    }

    /// Attaches a bare document of a given kind. The real pipeline is a later plan; the
    /// sweep only needs the links to exist.
    func attachDocumentForTesting(kind: DocumentKind, toEntry id: UUID) throws {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        let document = Document()
        document.kind = kind
        document.updatedAt = now()
        modelContext.insert(document)
        row.documents = (row.documents ?? []) + [document]
        row.updatedAt = now()
        try modelContext.save()
    }
}
