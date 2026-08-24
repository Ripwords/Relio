import Foundation
import SwiftData
import TaxKit

/// One Year of Assessment's income and household facts, as a value.
public struct YearFacts: Hashable, Sendable {
    public var grossIncome: Money?
    public var epf: Money?
    public var socso: Money?
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var propertyPrice: Money?
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    public init() {}
}

/// One entry, as a value. `id == nil` creates; a known `id` updates in place.
public struct EntryDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var year: Int
    public var code: ReliefCode
    public var amount: Money
    public var claimant: Claimant
    public var dependentID: UUID?
    public var vendor: String
    public var spentOn: Date?
    public var note: String
    /// Read-only for callers; the store owns it.
    public internal(set) var updatedAt: Date
    public internal(set) var needsDocument: Bool
    public internal(set) var documentKinds: Set<DocumentKind>

    public init(id: UUID = UUID(),
                year: Int,
                code: ReliefCode,
                amount: Money,
                claimant: Claimant = .individual,
                dependentID: UUID? = nil,
                vendor: String = "",
                spentOn: Date? = nil,
                note: String = "") {
        self.id = id
        self.year = year
        self.code = code
        self.amount = amount
        self.claimant = claimant
        self.dependentID = dependentID
        self.vendor = vendor
        self.spentOn = spentOn
        self.note = note
        self.updatedAt = .distantPast
        self.needsDocument = false
        self.documentKinds = []
    }
}

public struct DependentDraft: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: DependentKind
    public var dateOfBirth: Date?
    /// `nil` is "not asked yet", which the engine turns into a prompt. Never default
    /// this to `false`.
    public var isDisabled: Bool?
    public var yearStatuses: [DependentYearStatus]

    public init(id: UUID = UUID(),
                name: String = "",
                kind: DependentKind = .child,
                dateOfBirth: Date? = nil,
                isDisabled: Bool? = nil,
                yearStatuses: [DependentYearStatus] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.dateOfBirth = dateOfBirth
        self.isDisabled = isDisabled
        self.yearStatuses = yearStatuses
    }
}

public struct PreferencesSnapshot: Hashable, Sendable {
    public var accentName: String
    public var assistantEnabled: Bool
    public var captureQuality: CaptureQuality
    public var incomeModuleEnabled: Bool
    public var hasCompletedOnboarding: Bool
    public var lastViewedYear: Int

    public init(accentName: String = "default",
                assistantEnabled: Bool = true,
                captureQuality: CaptureQuality = .balanced,
                incomeModuleEnabled: Bool = false,
                hasCompletedOnboarding: Bool = false,
                lastViewedYear: Int = 0) {
        self.accentName = accentName
        self.assistantEnabled = assistantEnabled
        self.captureQuality = captureQuality
        self.incomeModuleEnabled = incomeModuleEnabled
        self.hasCompletedOnboarding = hasCompletedOnboarding
        self.lastViewedYear = lastViewedYear
    }
}

/// The only thing in the app allowed to write.
///
/// Every parameter and every return value is a `Sendable` value type, so a `@Model`
/// object cannot escape this actor. That is what makes "no view touches `modelContext`"
/// a structural property rather than a rule someone has to remember: a view has nothing
/// to touch. Spec §5.
@ModelActor
public actor TaxStore {

    /// Injected so tests can control `updatedAt`, which is what CloudKit's
    /// newest-write-wins and the reconciliation sweep both key off.
    ///
    /// Not `private`: `TaxStore+Reads.swift` reads it too. `useClock` remains the only
    /// mutator.
    var now: @Sendable () -> Date = { Date() }

    public func useClock(_ clock: @escaping @Sendable () -> Date) {
        now = clock
    }

    // MARK: - Years

    public func saveYearFacts(_ facts: YearFacts, for year: Int) throws {
        let stamp = now()
        let row = try fetchOrCreateYear(year)
        row.grossIncome = facts.grossIncome
        row.epf = facts.epf
        row.socso = facts.socso
        row.maritalStatus = facts.maritalStatus
        row.spouseHasIncome = facts.spouseHasIncome
        row.assessmentType = facts.assessmentType
        row.employmentType = facts.employmentType
        row.gender = facts.gender
        row.propertyPriceSen = facts.propertyPrice?.sen
        row.selfIsDisabled = facts.selfIsDisabled
        row.spouseIsDisabled = facts.spouseIsDisabled
        row.updatedAt = stamp
        try modelContext.save()
    }

    // MARK: - Entries

    @discardableResult
    public func save(_ draft: EntryDraft) throws -> UUID {
        let stamp = now()
        let year = try fetchOrCreateYear(draft.year)

        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? ReliefEntry(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.reliefCode = draft.code
        row.amount = draft.amount
        row.claimant = draft.claimant
        row.dependentID = draft.dependentID
        row.vendor = draft.vendor
        row.spentOn = draft.spentOn
        row.note = draft.note
        row.taxYear = year
        row.deletedAt = nil
        row.updatedAt = stamp
        year.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    /// Idempotent: deleting an id that is absent or already deleted is a no-op. The same
    /// delete can arrive twice — an undo toast tapped as a sync lands — and the second
    /// one must not crash a screen the user is looking at.
    public func softDeleteEntry(id: UUID) throws {
        guard let row = try entryRow(id) else { return }
        row.deletedAt = now()
        row.updatedAt = now()
        try modelContext.save()
    }

    public func restoreEntry(id: UUID) throws {
        guard let row = try entryRow(id) else { return }
        row.deletedAt = nil
        row.mergedInto = nil
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Dependents

    @discardableResult
    public func save(_ draft: DependentDraft) throws -> UUID {
        let stamp = now()
        let identifier = draft.id
        let existing = try modelContext.fetch(
            FetchDescriptor<Dependent>(predicate: #Predicate { $0.id == identifier })
        ).first

        let row = existing ?? Dependent(id: identifier)
        if existing == nil { modelContext.insert(row) }

        row.name = draft.name
        row.kind = draft.kind
        row.dateOfBirth = draft.dateOfBirth
        row.isDisabled = draft.isDisabled
        row.yearStatuses = draft.yearStatuses
        row.deletedAt = nil
        row.updatedAt = stamp

        try modelContext.save()
        return identifier
    }

    public func softDeleteDependent(id: UUID) throws {
        let descriptor = FetchDescriptor<Dependent>(predicate: #Predicate { $0.id == id })
        guard let row = try modelContext.fetch(descriptor).first else { return }
        row.deletedAt = now()
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Preferences

    public func savePreferences(_ snapshot: PreferencesSnapshot) throws {
        let row = try resolvedPreferencesRow() ?? {
            let fresh = UserPreferences()
            modelContext.insert(fresh)
            return fresh
        }()
        row.accentName = snapshot.accentName
        row.assistantEnabled = snapshot.assistantEnabled
        row.captureQuality = snapshot.captureQuality
        row.incomeModuleEnabled = snapshot.incomeModuleEnabled
        row.hasCompletedOnboarding = snapshot.hasCompletedOnboarding
        row.lastViewedYear = snapshot.lastViewedYear
        row.updatedAt = now()
        try modelContext.save()
    }

    // MARK: - Internals

    private func fetchOrCreateYear(_ year: Int) throws -> TaxYear {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        if let existing = try modelContext.fetch(descriptor).first { return existing }
        let fresh = TaxYear(year: year)
        fresh.updatedAt = now()
        modelContext.insert(fresh)
        return fresh
    }

    private func entryRow(_ id: UUID) throws -> ReliefEntry? {
        try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.id == id })
        ).first
    }

    /// CloudKit cannot enforce a singleton, so two devices first launching offline each
    /// create a preferences row. Keep the newest, soft-delete the rest — the same rule
    /// the reconciliation sweep applies to entries, so both converge the same way.
    private func resolvedPreferencesRow() throws -> UserPreferences? {
        let live = try modelContext
            .fetch(FetchDescriptor<UserPreferences>())
            .filter(\.isLive)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard let survivor = live.first else { return nil }
        // A losing preferences row carries no `mergedInto`: there is nothing to audit
        // in a settings row, only a value to keep.
        for loser in live.dropFirst() { loser.deletedAt = now() }
        return survivor
    }
}
