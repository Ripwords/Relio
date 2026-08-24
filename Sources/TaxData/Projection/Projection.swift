import Foundation
import SwiftData
import TaxKit

/// Everything `evaluate(ruleSet:year:entries:)` needs, and nothing else.
public struct ProjectedYear: Hashable, Sendable {
    public var snapshot: TaxYearSnapshot
    public var entries: [EntrySnapshot]
}

extension TaxStore {

    /// The seam between the store and the engine.
    ///
    /// Everything above this line is SwiftData; everything below it is the pure function
    /// Plan 1 golden-file tested. Ordering is deterministic so two devices, and two runs,
    /// produce byte-identical input to the engine.
    public func project(year: Int) throws -> ProjectedYear {
        let facts = try yearFacts(for: year)
        let entries = try entryDrafts(forYear: year)
        let dependents = try dependentDrafts()

        var snapshot = TaxYearSnapshot(year: year)
        snapshot.grossIncome = facts.grossIncome
        snapshot.maritalStatus = facts.maritalStatus
        snapshot.spouseHasIncome = facts.spouseHasIncome
        snapshot.assessmentType = facts.assessmentType
        snapshot.employmentType = facts.employmentType
        snapshot.gender = facts.gender
        snapshot.propertyPriceSen = facts.propertyPrice?.sen
        snapshot.selfIsDisabled = facts.selfIsDisabled
        snapshot.spouseIsDisabled = facts.spouseIsDisabled
        snapshot.dependents = dependents.map { Self.dependentSnapshot($0, forYear: year) }
        snapshot.lastClaimedYear = try claimHistory(before: year)

        return ProjectedYear(
            snapshot: snapshot,
            entries: entries.map { draft in
                EntrySnapshot(id: draft.id,
                              code: draft.code,
                              amount: draft.amount,
                              claimant: draft.claimant,
                              dependentID: draft.dependentID,
                              documentKinds: draft.documentKinds)
            })
    }

    static func dependentSnapshot(_ draft: DependentDraft, forYear year: Int) -> DependentSnapshot {
        let status = draft.yearStatuses.first { $0.year == year }
        return DependentSnapshot(
            id: draft.id,
            name: draft.name,
            ageAtYearEnd: draft.dateOfBirth.map { AgeCalculator.age(bornOn: $0, atEndOf: year) },
            // nil, not `.none`: an unrecorded education level is an unanswered question,
            // and the engine renders it as a prompt rather than as ineligibility.
            educationLevel: status?.educationLevel,
            isDisabled: draft.isDisabled,
            claimPercentage: status?.claimPercentage ?? 100)
    }

    /// The most recent prior year in which each code was claimed.
    ///
    /// Only codes with an actual entry in this store appear. A code with no history is
    /// absent, which the engine reads as `.unknown` — the app cannot know what a user
    /// claimed before adopting it, and assuming "never" would over-grant a
    /// once-every-N-years relief.
    private func claimHistory(before year: Int) throws -> [ReliefCode: Int] {
        let rows = try modelContext.fetch(
            FetchDescriptor<ReliefEntry>(predicate: #Predicate { $0.deletedAt == nil }))

        var history: [ReliefCode: Int] = [:]
        for row in rows {
            guard let rowYear = row.taxYear?.year, rowYear < year else { continue }
            let code = row.reliefCode
            history[code] = max(history[code] ?? Int.min, rowYear)
        }
        return history
    }
}
