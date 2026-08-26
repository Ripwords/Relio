import Foundation
import SwiftData
import TaxKit

/// One Year of Assessment for one taxpayer: their income facts and their entries.
///
/// Every stored property is optional or defaulted and no relationship is required,
/// because CloudKit mirroring rejects both. `SchemaInvariantTests` enforces this.
///
/// Enums and money are stored as raw `String`/`Int`. `#Predicate` pushes comparisons on
/// those into the store; through a `Codable` enum it would load every row and filter in
/// memory. The computed accessors below are the API; the `Raw` properties are storage.
@Model
public final class TaxYear {

    /// Stable across devices, unlike `persistentModelID` (a *local store* identity that
    /// two devices are not guaranteed to derive identically for the same logical row).
    /// `TaxStore.isNewer` uses this, not `persistentModelID`, to break ties when two
    /// devices each create a live `TaxYear` row for the same year — otherwise each
    /// device could pick a different survivor and the duplicate would never converge.
    public var id: UUID = UUID()

    public var year: Int = 0

    /// What the user says the year's gross income really was, overriding the figure
    /// derived from their income timeline.
    ///
    /// `nil` means "derive it". Their EA form is authoritative — it includes
    /// benefits-in-kind, allowances and anything they never logged — so the derived figure
    /// is a default, not the truth. Spec §6.
    public var grossIncomeOverrideSen: Int?

    public var maritalStatusRaw: String?
    public var spouseHasIncome: Bool?
    public var assessmentTypeRaw: String?
    public var employmentTypeRaw: String?
    public var genderRaw: String?

    /// Purchase price of the first home, for the tiered housing-loan-interest relief.
    public var propertyPriceSen: Int?

    /// JKM-registered disability, gating the two disabled-person reliefs.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    /// `.distantPast` means "never written through TaxStore". Reading the clock in a
    /// default would make two devices disagree about a row neither has touched.
    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    /// Cascade so deleting a year's record takes its entries with it. Note that nothing
    /// in the app hard-deletes a year; this is the safety net for a container reset.
    @Relationship(deleteRule: .cascade, inverse: \ReliefEntry.taxYear)
    public var entries: [ReliefEntry]?

    public init(year: Int = 0) {
        self.year = year
    }
}

extension TaxYear {

    public var grossIncomeOverride: Money? {
        get { grossIncomeOverrideSen.map(Money.init(sen:)) }
        set { grossIncomeOverrideSen = newValue?.sen }
    }

    public var maritalStatus: MaritalStatus? {
        get { maritalStatusRaw.flatMap(MaritalStatus.init(rawValue:)) }
        set { maritalStatusRaw = newValue?.rawValue }
    }

    public var assessmentType: AssessmentType? {
        get { assessmentTypeRaw.flatMap(AssessmentType.init(rawValue:)) }
        set { assessmentTypeRaw = newValue?.rawValue }
    }

    public var employmentType: EmploymentType? {
        get { employmentTypeRaw.flatMap(EmploymentType.init(rawValue:)) }
        set { employmentTypeRaw = newValue?.rawValue }
    }

    public var gender: Gender? {
        get { genderRaw.flatMap(Gender.init(rawValue:)) }
        set { genderRaw = newValue?.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }

    /// Entries that have not been soft-deleted or merged away.
    public var liveEntries: [ReliefEntry] {
        (entries ?? []).filter { $0.deletedAt == nil }
    }
}
