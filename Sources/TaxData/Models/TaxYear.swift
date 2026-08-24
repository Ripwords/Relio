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

    public var year: Int = 0

    public var grossIncomeSen: Int?
    public var epfSen: Int?
    public var socsoSen: Int?

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

    public init(year: Int = 0) {
        self.year = year
    }
}

extension TaxYear {

    public var grossIncome: Money? {
        get { grossIncomeSen.map(Money.init(sen:)) }
        set { grossIncomeSen = newValue?.sen }
    }

    public var epf: Money? {
        get { epfSen.map(Money.init(sen:)) }
        set { epfSen = newValue?.sen }
    }

    public var socso: Money? {
        get { socsoSen.map(Money.init(sen:)) }
        set { socsoSen = newValue?.sen }
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
}
