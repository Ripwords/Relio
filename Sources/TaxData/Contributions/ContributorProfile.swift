import Foundation

/// The two facts that decide which statutory rate applies to a wage month.
///
/// Both `nil` today for every user on every device. That is not a gap to paper over: with
/// neither fact known the admissible contributors include a Malaysian citizen aged 60 or
/// over, whose EPF rate is 0%, so the greatest amount the records prove is nothing at all.
public struct ContributorProfile: Hashable, Sendable {

    /// Stored rather than asked per year. The EPF rate switches at 60 and the social
    /// security category at 55, in different months of different years, so a year-scoped
    /// "are you 60 or over?" could express neither and would go stale besides.
    public var dateOfBirth: Date?

    public var nationality: NationalityClass?

    public init(dateOfBirth: Date? = nil, nationality: NationalityClass? = nil) {
        self.dateOfBirth = dateOfBirth
        self.nationality = nationality
    }
}

/// The contributor classes the statutory schedules distinguish.
public enum NationalityClass: String, Codable, Hashable, Sendable, CaseIterable {
    case malaysianCitizen
    case permanentResident
    /// Neither. EPF was voluntary for non-Malaysians before 1 October 2025.
    case other
}

/// What Relio needs answered before it can prove more than it currently can.
///
/// Deliberately not a `ProfileQuestion` case. `ProfileQuestion` is the vocabulary of
/// rulebook eligibility predicates, owned by TaxKit; these gate a TaxData payroll
/// derivation and no rulebook rule reads them, so putting them in TaxKit would export a
/// TaxData concern into the engine's public surface for nothing.
public enum ContributionQuestion: Hashable, Sendable {
    case dateOfBirth
    case nationality
    /// "Does this source deduct EPF from your pay?" — the `IncomeSource` flag that has
    /// existed since SchemaV1 and that nothing has ever written.
    case sourceDeducts(scheme: ContributionScheme, sourceID: UUID)
}
