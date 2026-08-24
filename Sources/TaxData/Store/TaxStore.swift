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

    /// Injectable so a test can pin a rulebook. Production uses the bundled one.
    private var ruleSetLoader: any RuleSetLoading = BundledRuleSetLoader()

    public func useRuleSetLoader(_ loader: any RuleSetLoading) {
        ruleSetLoader = loader
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
        // Editing an entry must revive it exactly as `restoreEntry` does: a row Task 6's
        // reconciliation sweep merged away still carries `mergedInto` pointing at the
        // survivor it lost to, and if `save` left that in place the revived row would be
        // live while still flagged as merged into something else. Both revival paths
        // must agree.
        row.mergedInto = nil
        row.updatedAt = stamp
        year.updatedAt = stamp
        refreshDerivedFields(on: row)

        try modelContext.save()
        return identifier
    }

    /// Idempotent: deleting an id that is absent or already deleted is a true no-op — it
    /// does not re-stamp `updatedAt`. The same delete can arrive twice (an undo toast
    /// tapped as a sync lands), and if the replay re-stamped the row, it would acquire a
    /// *newer* `updatedAt` than a legitimate concurrent edit or restore on another
    /// device and wrongly win newest-write-wins. Re-stamping only on the transition into
    /// deletion is what keeps a delete-vs-edit race from resolving as silent data loss.
    public func softDeleteEntry(id: UUID) throws {
        guard let row = try entryRow(id) else { return }
        guard row.deletedAt == nil else { return }
        // One reading of the clock, as everywhere else in this file: two calls leave
        // `deletedAt` and `updatedAt` microseconds apart, so a row's own two stamps
        // disagree about when the delete happened.
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
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
        // Same true-no-op guard as `softDeleteEntry`: a replayed delete on an
        // already-deleted row must not re-stamp it, or it can outrace a concurrent edit
        // or restore on another device.
        guard row.deletedAt == nil else { return }
        let stamp = now()
        row.deletedAt = stamp
        row.updatedAt = stamp
        try modelContext.save()
    }

    // MARK: - Preferences

    public func savePreferences(_ snapshot: PreferencesSnapshot) throws {
        // `persistingChanges: false`: this method's own `modelContext.save()` below
        // covers whatever `resolvedPreferencesRow` staged on the losing rows, so there
        // is no need to force an extra save here.
        let row = try resolvedPreferencesRow(persistingChanges: false) ?? {
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

    /// Total order two devices agree on when more than one live row could otherwise be
    /// picked: newest `updatedAt` first, ties broken on `id.uuidString` — the same rule
    /// every other resolver in this file uses (`resolvedPreferencesRow`,
    /// `entryDrafts`'s and `dependentDrafts`'s ordering). `id` is stable across devices;
    /// `persistentModelID` is a *local store* identity and is not guaranteed to agree
    /// across two devices for the same logical row, so it cannot serve as a tie-break —
    /// two devices could each pick a different survivor and the duplicate would never
    /// converge. Shared by the write path (`fetchOrCreateYear`) and the read path
    /// (`TaxStore+Reads.yearFacts`) so they can never disagree about which duplicate
    /// `TaxYear` row is "the" row for a year.
    static func isNewer(_ lhs: TaxYear, _ rhs: TaxYear) -> Bool {
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    private func fetchOrCreateYear(_ year: Int) throws -> TaxYear {
        let descriptor = FetchDescriptor<TaxYear>(
            predicate: #Predicate { $0.year == year && $0.deletedAt == nil })
        if let existing = try modelContext.fetch(descriptor).sorted(by: Self.isNewer).first {
            return existing
        }
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

    /// The two fields the store owns rather than the caller: a key that must never go
    /// stale, and a flag `#Predicate` needs because it cannot call the engine.
    ///
    /// Not `private`: the reconciliation sweep (`Reconciliation.swift`) calls this on a
    /// survivor after unioning in a loser's documents, so `needsDocument` reflects what
    /// the survivor now has rather than going stale until the user next edits the row.
    func refreshDerivedFields(on row: ReliefEntry) {
        row.dedupeKey = DedupeKey.entry(year: row.taxYear?.year ?? 0,
                                        code: row.reliefCode,
                                        amountSen: row.amountSen,
                                        day: Normalisation.day(row.spentOn),
                                        vendor: Normalisation.vendor(row.vendor),
                                        claimant: row.claimant,
                                        dependentID: row.dependentID)
        row.needsDocument = missingRequiredDocument(for: row)
    }

    /// A year whose rules this build does not ship yields `false`, not a warning: the
    /// app has no basis to claim a document is missing against rules it cannot read.
    private func missingRequiredDocument(for row: ReliefEntry) -> Bool {
        guard let year = row.taxYear?.year,
              let ruleSet = try? ruleSetLoader.ruleSet(for: year),
              let rule = ruleSet.relief(for: row.reliefCode) else { return false }
        return !Set(rule.requiredDocuments).isSubset(of: row.documentKinds)
    }

    /// Rewrites every live entry's key. Needed after a change to the normalisation rules
    /// or to the key's components, which would otherwise leave old rows unmatchable
    /// against new ones and silently break the sweep.
    public func recomputeAllDedupeKeys() throws {
        let rows = try modelContext
            .fetch(FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))
        for row in rows { refreshDerivedFields(on: row) }
        try modelContext.save()
    }

    /// CloudKit cannot enforce a singleton, so two devices first launching offline each
    /// create a preferences row. Keep the newest, soft-delete the rest — the same rule
    /// the reconciliation sweep applies to entries, so both converge the same way.
    ///
    /// Shared by the write path (`savePreferences`) and the read path
    /// (`TaxStore+Reads.preferences`) so they can never disagree about which row
    /// survives — two copies of this ordering rule is exactly what let the loser's
    /// `updatedAt` go unstamped in one path and not the other. `persistingChanges`
    /// controls whether the loser edits are flushed immediately: the write path folds
    /// them into its own subsequent `save()`, but the read path has no other save call
    /// and must persist here or the loser's stamp never reaches disk.
    func resolvedPreferencesRow(persistingChanges: Bool) throws -> UserPreferences? {
        let stamp = now()
        let live = try modelContext
            .fetch(FetchDescriptor<UserPreferences>())
            .filter(\.isLive)
            .sorted { ($0.updatedAt, $0.id.uuidString) > ($1.updatedAt, $1.id.uuidString) }
        guard let survivor = live.first else { return nil }
        // A losing preferences row carries no `mergedInto`: there is nothing to audit in
        // a settings row, only a value to keep. It still needs `updatedAt` stamped like
        // every other write, or the soft delete syncs with a stale stamp and can lose to
        // an older edit under newest-write-wins.
        for loser in live.dropFirst() {
            loser.deletedAt = stamp
            loser.updatedAt = stamp
        }
        if persistingChanges && live.count > 1 {
            try modelContext.save()
        }
        return survivor
    }
}
