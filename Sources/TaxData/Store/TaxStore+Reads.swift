import Foundation
import SwiftData
import TaxKit

extension TaxStore {

    /// Years that have a live `TaxYear` row, ascending, de-duplicated.
    ///
    /// This is what the *store* knows about, which is not the same list as the years the
    /// app can evaluate: a `TaxYear` row exists for any year the user has entries or
    /// facts in, whether or not a rulebook for it shipped. Nothing calls this yet.
    ///
    /// When the year switcher is built it should show the union of this and
    /// `RuleSetLoading.availableYears`, not either alone — the loader's list alone hides
    /// a year the user has entries in but no rulebook for (every January until the
    /// Budget ships), and this list alone hides a shipped year they have not touched.
    /// `YearContext` already renders the no-rulebook case as `.unavailable`, so such a
    /// year is safe to offer.
    public func liveYears() throws -> [Int] {
        let years = try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))
            .map(\.year)
        return Array(Set(years)).sorted()
    }

    public func yearFacts(for year: Int) throws -> YearFacts {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        // Two devices first launching offline can each create a live `TaxYear` row for
        // the same year; `TaxStore.isNewer` is the same total order `fetchOrCreateYear`
        // uses, so the read and write paths agree on which row is "the" row.
        guard let row = try modelContext.fetch(descriptor).sorted(by: TaxStore.isNewer).first else {
            return YearFacts()
        }

        var facts = YearFacts()
        facts.grossIncome = row.grossIncome
        facts.epf = row.epf
        facts.socso = row.socso
        facts.maritalStatus = row.maritalStatus
        facts.spouseHasIncome = row.spouseHasIncome
        facts.assessmentType = row.assessmentType
        facts.employmentType = row.employmentType
        facts.gender = row.gender
        facts.propertyPrice = row.propertyPriceSen.map(Money.init(sen:))
        facts.selfIsDisabled = row.selfIsDisabled
        facts.spouseIsDisabled = row.spouseIsDisabled
        return facts
    }

    /// Live entries for a year, ordered deterministically by id so two devices agree.
    ///
    /// `#Predicate { $0.taxYear?.year == year }` traverses an optional relationship,
    /// which SwiftData's in-store predicate translator cannot always push into the
    /// store. Verified directly (see the task report): on this SwiftData runtime it
    /// compiles and correctly filters by year, so the predicate is pushed into the
    /// store rather than fetching every live entry and filtering in Swift. If this ever
    /// regresses, the brief's fallback is: fetch `FetchDescriptor<ReliefEntry>(predicate:
    /// #Predicate { $0.deletedAt == nil })`, then `.filter { $0.taxYear?.year == year }`
    /// in Swift.
    public func entryDrafts(forYear year: Int) throws -> [EntryDraft] {
        let descriptor = FetchDescriptor<ReliefEntry>(
            predicate: #Predicate { $0.taxYear?.year == year && $0.deletedAt == nil })
        return try modelContext.fetch(descriptor)
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map(Self.draft(from:))
    }

    public func dependentDrafts() throws -> [DependentDraft] {
        try modelContext
            .fetch(FetchDescriptor<Dependent>(predicate: #Predicate { $0.deletedAt == nil }))
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { row in
                DependentDraft(id: row.id,
                               name: row.name,
                               kind: row.kind,
                               dateOfBirth: row.dateOfBirth,
                               isDisabled: row.isDisabled,
                               yearStatuses: row.yearStatuses.sorted { $0.year < $1.year })
            }
    }

    public func preferences() throws -> PreferencesSnapshot {
        // `persistingChanges: true`: unlike `savePreferences`, this call has no
        // subsequent `modelContext.save()`, so any loser rows the resolver stamped
        // must be flushed here or the stamp never reaches disk.
        guard let row = try resolvedPreferencesRow(persistingChanges: true) else {
            return PreferencesSnapshot()
        }
        return PreferencesSnapshot(accentName: row.accentName,
                                   assistantEnabled: row.assistantEnabled,
                                   captureQuality: row.captureQuality,
                                   incomeModuleEnabled: row.incomeModuleEnabled,
                                   hasCompletedOnboarding: row.hasCompletedOnboarding,
                                   lastViewedYear: row.lastViewedYear)
    }

    /// The stored key for one entry. Exposed for the dedupe tests and for the merge UI.
    public func dedupeKey(forEntry id: UUID) throws -> String {
        let descriptor = FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        return try modelContext.fetch(descriptor).first?.dedupeKey ?? ""
    }

    static func draft(from row: ReliefEntry) -> EntryDraft {
        var draft = EntryDraft(id: row.id,
                               year: row.taxYear?.year ?? 0,
                               code: row.reliefCode,
                               amount: row.amount,
                               claimant: row.claimant,
                               dependentID: row.dependentID,
                               vendor: row.vendor,
                               spentOn: row.spentOn,
                               note: row.note)
        draft.updatedAt = row.updatedAt
        draft.needsDocument = row.needsDocument
        draft.documentKinds = row.documentKinds
        return draft
    }
}

// MARK: - Test-only seams

extension TaxStore {

    /// Creates the collision CloudKit can produce but a single device cannot: a second
    /// live preferences row. Only the tests call this.
    func insertDuplicatePreferencesForTesting(incomeModuleEnabled: Bool) throws {
        let row = UserPreferences()
        row.incomeModuleEnabled = incomeModuleEnabled
        row.updatedAt = now()
        modelContext.insert(row)
        try modelContext.save()
    }

    func livePreferenceRowCount() throws -> Int {
        try modelContext.fetch(FetchDescriptor<UserPreferences>()).filter(\.isLive).count
    }

    /// Every preferences row's `updatedAt`, live or soft-deleted, so tests can verify a
    /// losing row in the CloudKit-singleton collision was stamped with the clock active
    /// when it lost rather than left at its original value. Only the tests call this.
    func allPreferencesUpdatedAtForTesting() throws -> [Date] {
        try modelContext.fetch(FetchDescriptor<UserPreferences>()).map(\.updatedAt)
    }

    /// Reads a `ReliefEntry`'s stamp regardless of `deletedAt`, so tests can verify a
    /// repeated soft delete did not re-stamp a row the public read API hides once it is
    /// deleted. Only the tests call this.
    func entryUpdatedAtForTesting(id: UUID) throws -> Date? {
        try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        ).first?.updatedAt
    }

    /// Sets `mergedInto` directly, simulating what Task 6's reconciliation sweep will do
    /// to a losing row, so tests can verify a subsequent `save` clears it the same way
    /// `restoreEntry` does. Only the tests call this.
    func setMergedIntoForTesting(id: UUID, mergedInto: UUID) throws {
        guard let row = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        ).first else { return }
        row.mergedInto = mergedInto
        try modelContext.save()
    }

    /// Reads `mergedInto` regardless of `deletedAt`. Only the tests call this.
    func entryMergedIntoForTesting(id: UUID) throws -> UUID? {
        try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        ).first?.mergedInto
    }

    /// Reads a `Dependent`'s stamp regardless of `deletedAt`. Only the tests call this.
    func dependentUpdatedAtForTesting(id: UUID) throws -> Date? {
        try modelContext.fetch(
            FetchDescriptor<Dependent>(predicate: #Predicate { $0.id == id })
        ).first?.updatedAt
    }

    /// Creates the collision CloudKit can produce but a single device cannot: a second
    /// live `TaxYear` row for the same year. Takes an explicit `id` so a tie-break test
    /// can pin which of two identically-stamped rows must win, rather than depending on
    /// whichever UUID `TaxYear.init` happens to generate. Only the tests call this.
    func insertDuplicateYearForTesting(id: UUID = UUID(), year: Int, updatedAt: Date, grossIncome: Money?) throws {
        let row = TaxYear(year: year)
        row.id = id
        row.updatedAt = updatedAt
        row.grossIncome = grossIncome
        modelContext.insert(row)
        try modelContext.save()
    }

    /// Every live `TaxYear` row's `grossIncome` for a year, ordered by the same
    /// `TaxStore.isNewer` rule the store applies, so tests can confirm the write and
    /// read paths pick the same survivor and leave the loser row untouched (Task 4's
    /// scope explicitly excludes merging duplicate `TaxYear` rows). Only the tests call
    /// this.
    func liveYearGrossIncomesForTesting(year: Int) throws -> [Money?] {
        try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.year == year && $0.deletedAt == nil }))
            .sorted(by: TaxStore.isNewer)
            .map(\.grossIncome)
    }

    /// Every live `TaxYear` row's `id` for a year, ordered by the same `TaxStore.isNewer`
    /// rule the store applies — so a tie-break test can assert exactly which id survives
    /// when two rows share an `updatedAt`. Only the tests call this.
    func liveYearIdsForTesting(year: Int) throws -> [UUID] {
        try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.year == year && $0.deletedAt == nil }))
            .sorted(by: TaxStore.isNewer)
            .map(\.id)
    }
}
