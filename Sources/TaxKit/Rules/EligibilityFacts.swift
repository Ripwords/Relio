import Foundation

public enum MaritalStatus: String, Codable, Hashable, Sendable, CaseIterable {
    case single, married, divorced, widowed
}

public enum AssessmentType: String, Codable, Hashable, Sendable, CaseIterable {
    case separate, joint, combinedUnderSpouse
}

public enum EmploymentType: String, Codable, Hashable, Sendable, CaseIterable {
    case privateSector, publicServantPensionable, selfEmployed
}

public enum Gender: String, Codable, Hashable, Sendable, CaseIterable {
    case female, male, unspecified
}

/// Who a claim is made in respect of.
public enum Claimant: String, Codable, Hashable, Sendable, CaseIterable {
    case individual = "self"
    case spouse, child, parent, grandparent
}

public enum EducationLevel: String, Codable, Hashable, Sendable, CaseIterable {
    case none, preTertiary, tertiaryLocal, tertiaryOverseas
}

/// Whether a once-every-N-years relief has been claimed before.
public enum ClaimHistory: Hashable, Sendable {
    case unknown
    case neverClaimed
    case lastClaimed(yearsAgo: Int)
}

/// A fact the app does not yet know, phrased as something to ask the user.
/// Each case maps to one prompt on the home screen and one topic for the assistant.
public enum ProfileQuestion: String, Codable, Hashable, Sendable, CaseIterable {
    case maritalStatus
    case spouseHasIncome
    case assessmentType
    case employmentType
    case gender
    case dependentDetails
    case lastClaimYear
    case propertyPrice
    case disabilityStatus
    case spouseDisabilityStatus
}

public struct DependentFacts: Hashable, Sendable {
    public var ageAtYearEnd: Int?
    public var educationLevel: EducationLevel?
    public var isDisabled: Bool?

    public init(ageAtYearEnd: Int? = nil,
                educationLevel: EducationLevel? = nil,
                isDisabled: Bool? = nil) {
        self.ageAtYearEnd = ageAtYearEnd
        self.educationLevel = educationLevel
        self.isDisabled = isDisabled
    }
}

/// Everything a predicate may ask about. `nil` means "not yet known", which produces
/// `.unknown` rather than a failure.
public struct Facts: Hashable, Sendable {
    public var yearOfAssessment: Int
    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var claimant: Claimant?
    public var dependent: DependentFacts?
    public var claimHistory: ClaimHistory
    public var propertyPriceSen: Int?
    /// Whether the taxpayer is a person with disabilities registered with JKM.
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    public init(yearOfAssessment: Int,
                maritalStatus: MaritalStatus? = nil,
                spouseHasIncome: Bool? = nil,
                assessmentType: AssessmentType? = nil,
                employmentType: EmploymentType? = nil,
                gender: Gender? = nil,
                claimant: Claimant? = nil,
                dependent: DependentFacts? = nil,
                claimHistory: ClaimHistory = .unknown,
                propertyPriceSen: Int? = nil,
                selfIsDisabled: Bool? = nil,
                spouseIsDisabled: Bool? = nil) {
        self.yearOfAssessment = yearOfAssessment
        self.maritalStatus = maritalStatus
        self.spouseHasIncome = spouseHasIncome
        self.assessmentType = assessmentType
        self.employmentType = employmentType
        self.gender = gender
        self.claimant = claimant
        self.dependent = dependent
        self.claimHistory = claimHistory
        self.propertyPriceSen = propertyPriceSen
        self.selfIsDisabled = selfIsDisabled
        self.spouseIsDisabled = spouseIsDisabled
    }
}

/// Three-valued, because "we have not asked yet" is not the same as "no".
public enum PredicateOutcome: Hashable, Sendable {
    case satisfied
    case failed(reason: String)
    case unknown(missing: [ProfileQuestion])
}
