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
        // The user's own figure wins; otherwise derive it from the timeline. `nil` here
        // means "not known", which the engine renders as no tax figures at all — quite
        // different from zero, which would claim they earned nothing.
        snapshot.grossIncome = try facts.grossIncomeOverride ?? derivedGrossIfKnown(for: year)
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

    /// The gross derived from the income timeline, or `nil` when nothing in that timeline
    /// reaches into this year — no source has a record whose contribution window touches
    /// it. Without this the engine would be handed a confident RM 0.00 income for a year
    /// the household has told us nothing about: an empty store, a source created before its
    /// first rate was saved, a year before the timeline begins, or a source that stopped
    /// paying in an earlier year.
    private func derivedGrossIfKnown(for year: Int) throws -> Money? {
        IncomeDerivation.knownAnnualGross(for: year, from: try incomeSnapshots())
    }

    static func dependentSnapshot(_ draft: DependentDraft, forYear year: Int) -> DependentSnapshot {
        let status = draft.yearStatuses.first { $0.year == year }
        return DependentSnapshot(
            id: draft.id,
            name: draft.name,
            // A negative age (bad data entry, or a placeholder DOB after the year end)
            // must not reach the engine: `dependentAge(max:)` tests `age > max`, and an
            // unclamped negative would satisfy that check, silently granting an
            // age-gated relief to a not-yet-born dependent. `ageAtYearEnd` is `Int?`, so
            // clamping to nil here reaches the engine as an unanswered question — the
            // relief prompts instead of being silently granted. AgeCalculator itself
            // stays the honest primitive and returns the real signed difference; this
            // is the one place the contract is enforced.
            ageAtYearEnd: draft.dateOfBirth
                .map { AgeCalculator.age(bornOn: $0, atEndOf: year) }
                .flatMap { $0 >= 0 ? $0 : nil },
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
