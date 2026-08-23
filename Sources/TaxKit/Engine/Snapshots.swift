import Foundation

/// A dependent as the engine sees them. Ages are resolved at year end by the caller,
/// so the engine never touches a calendar.
public struct DependentSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var ageAtYearEnd: Int?
    public var educationLevel: EducationLevel?
    public var isDisabled: Bool?
    /// 100 when claimed in full, 50 when split with a spouse.
    public var claimPercentage: Int

    public init(id: UUID = UUID(),
                name: String = "",
                ageAtYearEnd: Int? = nil,
                educationLevel: EducationLevel? = nil,
                isDisabled: Bool? = nil,
                claimPercentage: Int = 100) {
        self.id = id
        self.name = name
        self.ageAtYearEnd = ageAtYearEnd
        self.educationLevel = educationLevel
        self.isDisabled = isDisabled
        self.claimPercentage = claimPercentage
    }

    var facts: DependentFacts {
        DependentFacts(ageAtYearEnd: ageAtYearEnd,
                       educationLevel: educationLevel,
                       isDisabled: isDisabled)
    }
}

/// One Year of Assessment's household and income facts. Every optional means
/// "not yet known", which produces `.needsInfo` rather than a silent ineligibility.
public struct TaxYearSnapshot: Hashable, Sendable {
    public var year: Int
    /// Aggregate income before any relief. `nil` disables all tax-saved maths.
    public var grossIncome: Money?
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var dependents: [DependentSnapshot]
    /// Purchase price of the first home, for tiered housing loan interest relief.
    public var propertyPriceSen: Int?
    /// JKM-registered disability status, gating the two disabled-person reliefs.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?
    /// The most recent YA in which a once-every-N-years relief was claimed.
    public var lastClaimedYear: [ReliefCode: Int]

    public init(year: Int,
                grossIncome: Money? = nil,
                maritalStatus: MaritalStatus? = nil,
                spouseHasIncome: Bool? = nil,
                assessmentType: AssessmentType? = nil,
                employmentType: EmploymentType? = nil,
                gender: Gender? = nil,
                dependents: [DependentSnapshot] = [],
                propertyPriceSen: Int? = nil,
                selfIsDisabled: Bool? = nil,
                spouseIsDisabled: Bool? = nil,
                lastClaimedYear: [ReliefCode: Int] = [:]) {
        self.year = year
        self.grossIncome = grossIncome
        self.maritalStatus = maritalStatus
        self.spouseHasIncome = spouseHasIncome
        self.assessmentType = assessmentType
        self.employmentType = employmentType
        self.gender = gender
        self.dependents = dependents
        self.propertyPriceSen = propertyPriceSen
        self.selfIsDisabled = selfIsDisabled
        self.spouseIsDisabled = spouseIsDisabled
        self.lastClaimedYear = lastClaimedYear
    }
}

/// One logged claim line.
public struct EntrySnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var code: ReliefCode
    public var amount: Money
    public var claimant: Claimant
    public var dependentID: UUID?
    /// The kinds of document attached, for requirement checking.
    public var documentKinds: Set<DocumentKind>

    public init(id: UUID = UUID(),
                code: ReliefCode,
                amount: Money,
                claimant: Claimant = .individual,
                dependentID: UUID? = nil,
                documentKinds: Set<DocumentKind> = []) {
        self.id = id
        self.code = code
        self.amount = amount
        self.claimant = claimant
        self.dependentID = dependentID
        self.documentKinds = documentKinds
    }
}
