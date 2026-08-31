import Foundation
import SwiftData
import TaxKit

extension TaxStore {

    public func contributorProfile() throws -> ContributorProfile {
        // `persistingChanges: true`, for `preferences()`'s reason: unlike the write paths
        // this call has no subsequent `modelContext.save()`, so any loser rows the
        // resolver stamped must be flushed here or the stamp never reaches disk.
        guard let row = try resolvedPreferencesRow(persistingChanges: true) else {
            return ContributorProfile()
        }
        return ContributorProfile(dateOfBirth: row.dateOfBirth, nationality: row.nationality)
    }

    /// Writes the two profile fields and only those, where `savePreferences` writes the
    /// others and only those.
    ///
    /// The disjointness is deliberate, not an accident of two methods growing separately.
    /// Both write the same CloudKit-synced singleton, so a settings save that also wrote
    /// the profile would null the date of birth every time the user changed their accent
    /// colour, and the answer they gave would silently revert to unasked.
    public func saveContributorProfile(_ profile: ContributorProfile) throws {
        // `persistingChanges: false`: this method's own `modelContext.save()` below covers
        // whatever `resolvedPreferencesRow` staged on the losing rows.
        let row = try resolvedPreferencesRow(persistingChanges: false) ?? {
            let fresh = UserPreferences()
            modelContext.insert(fresh)
            return fresh
        }()
        row.dateOfBirth = profile.dateOfBirth
        row.nationality = profile.nationality
        row.updatedAt = now()
        try modelContext.save()
    }

    /// The floor under a year's statutory contributions, from the profile and the income
    /// timeline this store holds.
    ///
    /// Both reads live here rather than at the call site because `TaxStore` is a
    /// `@ModelActor`: one method body is one uninterruptible actor turn, so the profile and
    /// the snapshots cannot come from two different stores. Two separate calls from a view
    /// model could interleave with a write, and the screen would then show a floor computed
    /// from a profile it is not displaying — the same read-tearing `incomeSummary` was
    /// collapsed into one fetch to prevent.
    public func contributionEstimate(scheme: ContributionScheme,
                                     year: Int) throws -> ContributionEstimate {
        ContributionDerivation.estimate(scheme: scheme,
                                        year: year,
                                        from: try incomeSnapshots(),
                                        profile: try contributorProfile())
    }
}
