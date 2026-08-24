import Foundation
import SwiftData
import TaxKit

extension TaxStore {

    /// Years that have any live row, ascending. Drives the year switcher.
    public func liveYears() throws -> [Int] {
        let years = try modelContext
            .fetch(FetchDescriptor<TaxYear>(predicate: #Predicate { $0.deletedAt == nil }))
            .map(\.year)
        return Array(Set(years)).sorted()
    }

    public func yearFacts(for year: Int) throws -> YearFacts {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        guard let row = try modelContext.fetch(descriptor).first else { return YearFacts() }

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
        guard let row = try resolvedPreferencesRowForReading() else { return PreferencesSnapshot() }
        return PreferencesSnapshot(accentName: row.accentName,
                                   assistantEnabled: row.assistantEnabled,
                                   captureQuality: row.captureQuality,
                                   incomeModuleEnabled: row.incomeModuleEnabled,
                                   hasCompletedOnboarding: row.hasCompletedOnboarding,
                                   lastViewedYear: row.lastViewedYear)
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

    private func resolvedPreferencesRowForReading() throws -> UserPreferences? {
        let live = try modelContext
            .fetch(FetchDescriptor<UserPreferences>())
            .filter(\.isLive)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard let survivor = live.first else { return nil }
        for loser in live.dropFirst() { loser.deletedAt = now() }
        if live.count > 1 { try modelContext.save() }
        return survivor
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
}
