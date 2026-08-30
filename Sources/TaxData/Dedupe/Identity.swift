import Foundation

/// Identities the app writes on the user's behalf rather than minting per install.
///
/// A fixed UUID, not a fresh one: two devices onboarding offline must write the *same*
/// row, or the user gets two "Main job" sources and double-counted income for every year,
/// with both rows looking correct. Sharing the id is what makes the duplicate *provable*,
/// and a provable duplicate is the only kind this package merges without asking — the
/// merge is irreversible, since `IncomeSource` has no `mergedInto` column and `SchemaV1`
/// is frozen.
///
/// Internal: no caller outside `TaxData` should need to name a row's identity. Onboarding
/// asks for `seedPrimaryEmployment`, which owns this.
enum WellKnownID {

    /// The employment source onboarding seeds. Pinned by
    /// `IncomeIdentityTests.primaryEmploymentIdentityIsPinned` — changing it strands every
    /// already-seeded row as an unmatchable orphan.
    static let primaryEmployment = UUID(uuidString: "6B1F0C2E-9A47-4D31-8E55-0F2A7C4D9B10")!

    /// The opening monthly rate a seed writes for one source in one calendar year.
    ///
    /// Derived, not stored: two devices must compute the same value with nothing
    /// coordinating them.
    ///
    /// The year is part of the tuple, and only the year: onboarding a *different* year is
    /// a different rate that should chain onto the timeline rather than collide with what
    /// is already there, while two devices whose users picked different start dates within
    /// one year are answering the same question and must land on one row.
    static func openingRate(forSource sourceID: UUID, effectiveFrom: Date) -> UUID {
        // Reuses `DedupeKey`'s encoder for the reason that file documents: a delimiter
        // join is not injective, and `uuidString` is the only component here we control.
        let digest = DedupeKey.digest(of: ["income.openingRate",
                                           sourceID.uuidString,
                                           String(IncomeCalendar.year(of: effectiveFrom))])
        var bytes = Array(digest.prefix(16))
        // RFC 4122 version 4 and variant bits. SwiftData and CloudKit both round-trip
        // these through their own UUID types, so a value that is not well formed is a risk
        // with no upside.
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
