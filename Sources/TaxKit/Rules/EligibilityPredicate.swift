import Foundation

/// A closed, non-executable condition tree.
///
/// Deliberately not a scripting language: every case is enumerable in Swift, so the
/// rulebook can never do anything the engine has not been written and tested to handle.
public indirect enum EligibilityPredicate: Codable, Hashable, Sendable {
    case always
    case all([EligibilityPredicate])
    case any([EligibilityPredicate])
    case not(EligibilityPredicate)

    case maritalStatus(in: [MaritalStatus])
    case spouseHasIncome(Bool)
    case assessmentType(AssessmentType)
    case employmentType(in: [EmploymentType])
    case gender(Gender)
    case selfIsDisabled(Bool)
    case spouseIsDisabled(Bool)
    case claimant(in: [Claimant])
    case dependentAge(min: Int?, max: Int?)
    case dependentEducation(in: [EducationLevel])
    case dependentIsDisabled(Bool)
    case yaRange(from: Int?, to: Int?)
    case claimFrequency(everyNYears: Int)

    // MARK: Evaluation

    public func evaluate(_ facts: Facts) -> PredicateOutcome {
        switch self {
        case .always:
            return .satisfied

        case .all(let children):
            var missing: [ProfileQuestion] = []
            for child in children {
                switch child.evaluate(facts) {
                case .satisfied: continue
                case .failed(let reason): return .failed(reason: reason)
                case .unknown(let questions): missing.append(contentsOf: questions)
                }
            }
            return missing.isEmpty ? .satisfied : .unknown(missing: missing.deduplicated())

        case .any(let children):
            var missing: [ProfileQuestion] = []
            var reasons: [String] = []
            for child in children {
                switch child.evaluate(facts) {
                case .satisfied: return .satisfied
                case .failed(let reason): reasons.append(reason)
                case .unknown(let questions): missing.append(contentsOf: questions)
                }
            }
            if !missing.isEmpty { return .unknown(missing: missing.deduplicated()) }
            return .failed(reason: reasons.joined(separator: "; or "))

        case .not(let child):
            switch child.evaluate(facts) {
            case .satisfied: return .failed(reason: "Condition must not hold")
            case .failed: return .satisfied
            case .unknown(let questions): return .unknown(missing: questions)
            }

        case .maritalStatus(let allowed):
            return Self.check(facts.maritalStatus, in: allowed,
                              asking: .maritalStatus, label: "Marital status")

        case .spouseHasIncome(let required):
            return Self.check(facts.spouseHasIncome, equals: required,
                              asking: .spouseHasIncome,
                              label: required ? "Spouse must have income"
                                              : "Spouse must have no income")

        case .assessmentType(let required):
            return Self.check(facts.assessmentType, in: [required],
                              asking: .assessmentType, label: "Assessment type")

        case .employmentType(let allowed):
            return Self.check(facts.employmentType, in: allowed,
                              asking: .employmentType, label: "Employment type")

        case .gender(let required):
            return Self.check(facts.gender, in: [required],
                              asking: .gender, label: "Gender")

        case .selfIsDisabled(let required):
            return Self.check(facts.selfIsDisabled, equals: required,
                              asking: .disabilityStatus,
                              label: required ? "You must be a registered disabled person"
                                              : "You must not be registered disabled")

        case .spouseIsDisabled(let required):
            return Self.check(facts.spouseIsDisabled, equals: required,
                              asking: .spouseDisabilityStatus,
                              label: required ? "Spouse must be a registered disabled person"
                                              : "Spouse must not be registered disabled")

        case .claimant(let allowed):
            // A claimant list scopes WHO an entry may be for; it is validated per entry,
            // not as a household gate. With no entry in context there is nothing to
            // refuse, so an absent claimant is satisfied rather than a question.
            // Per-entry claimant validation belongs to Plan 2, which owns the UI that
            // records it.
            guard let claimant = facts.claimant else { return .satisfied }
            return allowed.contains(claimant)
                ? .satisfied
                : .failed(reason: "Claimed for must be \(Self.describe(allowed))")

        case .dependentAge(let min, let max):
            guard let age = facts.dependent?.ageAtYearEnd else {
                return .unknown(missing: [.dependentDetails])
            }
            if let min, age < min {
                return .failed(reason: "Dependent must be at least \(min) years old")
            }
            if let max, age > max {
                return .failed(reason: "Dependent must be \(max) years old or under")
            }
            return .satisfied

        case .dependentEducation(let allowed):
            return Self.check(facts.dependent?.educationLevel, in: allowed,
                              asking: .dependentDetails, label: "Education level")

        case .dependentIsDisabled(let required):
            return Self.check(facts.dependent?.isDisabled, equals: required,
                              asking: .dependentDetails,
                              label: required ? "Dependent must be disabled"
                                              : "Dependent must not be disabled")

        case .yaRange(let from, let to):
            let ya = facts.yearOfAssessment
            if let from, ya < from { return .failed(reason: "Not available before YA\(from)") }
            if let to, ya > to { return .failed(reason: "Not available after YA\(to)") }
            return .satisfied

        case .claimFrequency(let everyNYears):
            switch facts.claimHistory {
            case .unknown:
                return .unknown(missing: [.lastClaimYear])
            case .neverClaimed:
                return .satisfied
            case .lastClaimed(let yearsAgo):
                return yearsAgo >= everyNYears
                    ? .satisfied
                    : .failed(reason: "Claimable once every \(everyNYears) years of assessment")
            }
        }
    }

    private static func check<T: Equatable>(_ value: T?,
                                            in allowed: [T],
                                            asking question: ProfileQuestion,
                                            label: String) -> PredicateOutcome {
        guard let value else { return .unknown(missing: [question]) }
        return allowed.contains(value)
            ? .satisfied
            : .failed(reason: "\(label) must be \(Self.describe(allowed))")
    }

    private static func check<T: Equatable>(_ value: T?,
                                            equals required: T,
                                            asking question: ProfileQuestion,
                                            label: String) -> PredicateOutcome {
        guard let value else { return .unknown(missing: [question]) }
        return value == required ? .satisfied : .failed(reason: label)
    }

    private static func describe<T>(_ allowed: [T]) -> String {
        let described = allowed.map { value -> String in
            (value as? any RawRepresentable).map { "\($0.rawValue)" } ?? "\(value)"
        }
        return described.joined(separator: " or ")
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case op, of, `in`, `is`, min, max, from, to, everyNYears
    }
    private enum Op: String, Codable {
        case always, all, any, not
        case maritalStatus, spouseHasIncome, assessmentType, employmentType, gender
        case selfIsDisabled, spouseIsDisabled
        case claimant, dependentAge, dependentEducation, dependentIsDisabled
        case yaRange, claimFrequency
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Op.self, forKey: .op) {
        case .always: self = .always
        case .all:    self = .all(try c.decode([EligibilityPredicate].self, forKey: .of))
        case .any:    self = .any(try c.decode([EligibilityPredicate].self, forKey: .of))
        case .not:
            let children = try c.decode([EligibilityPredicate].self, forKey: .of)
            guard children.count == 1 else {
                throw DecodingError.dataCorruptedError(
                    forKey: .of, in: c, debugDescription: "not takes exactly one operand")
            }
            self = .not(children[0])
        case .maritalStatus:
            self = .maritalStatus(in: try c.decode([MaritalStatus].self, forKey: .in))
        case .spouseHasIncome:
            self = .spouseHasIncome(try c.decode(Bool.self, forKey: .is))
        case .assessmentType:
            self = .assessmentType(try c.decode(AssessmentType.self, forKey: .is))
        case .employmentType:
            self = .employmentType(in: try c.decode([EmploymentType].self, forKey: .in))
        case .gender:
            self = .gender(try c.decode(Gender.self, forKey: .is))
        case .selfIsDisabled:
            self = .selfIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .spouseIsDisabled:
            self = .spouseIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .claimant:
            self = .claimant(in: try c.decode([Claimant].self, forKey: .in))
        case .dependentAge:
            self = .dependentAge(min: try c.decodeIfPresent(Int.self, forKey: .min),
                                 max: try c.decodeIfPresent(Int.self, forKey: .max))
        case .dependentEducation:
            self = .dependentEducation(in: try c.decode([EducationLevel].self, forKey: .in))
        case .dependentIsDisabled:
            self = .dependentIsDisabled(try c.decode(Bool.self, forKey: .is))
        case .yaRange:
            self = .yaRange(from: try c.decodeIfPresent(Int.self, forKey: .from),
                            to: try c.decodeIfPresent(Int.self, forKey: .to))
        case .claimFrequency:
            self = .claimFrequency(everyNYears: try c.decode(Int.self, forKey: .everyNYears))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .always:
            try c.encode(Op.always, forKey: .op)
        case .all(let children):
            try c.encode(Op.all, forKey: .op); try c.encode(children, forKey: .of)
        case .any(let children):
            try c.encode(Op.any, forKey: .op); try c.encode(children, forKey: .of)
        case .not(let child):
            try c.encode(Op.not, forKey: .op); try c.encode([child], forKey: .of)
        case .maritalStatus(let allowed):
            try c.encode(Op.maritalStatus, forKey: .op); try c.encode(allowed, forKey: .in)
        case .spouseHasIncome(let value):
            try c.encode(Op.spouseHasIncome, forKey: .op); try c.encode(value, forKey: .is)
        case .assessmentType(let value):
            try c.encode(Op.assessmentType, forKey: .op); try c.encode(value, forKey: .is)
        case .employmentType(let allowed):
            try c.encode(Op.employmentType, forKey: .op); try c.encode(allowed, forKey: .in)
        case .gender(let value):
            try c.encode(Op.gender, forKey: .op); try c.encode(value, forKey: .is)
        case .selfIsDisabled(let value):
            try c.encode(Op.selfIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .spouseIsDisabled(let value):
            try c.encode(Op.spouseIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .claimant(let allowed):
            try c.encode(Op.claimant, forKey: .op); try c.encode(allowed, forKey: .in)
        case .dependentAge(let min, let max):
            try c.encode(Op.dependentAge, forKey: .op)
            try c.encodeIfPresent(min, forKey: .min); try c.encodeIfPresent(max, forKey: .max)
        case .dependentEducation(let allowed):
            try c.encode(Op.dependentEducation, forKey: .op); try c.encode(allowed, forKey: .in)
        case .dependentIsDisabled(let value):
            try c.encode(Op.dependentIsDisabled, forKey: .op); try c.encode(value, forKey: .is)
        case .yaRange(let from, let to):
            try c.encode(Op.yaRange, forKey: .op)
            try c.encodeIfPresent(from, forKey: .from); try c.encodeIfPresent(to, forKey: .to)
        case .claimFrequency(let n):
            try c.encode(Op.claimFrequency, forKey: .op); try c.encode(n, forKey: .everyNYears)
        }
    }
}

extension Array where Element: Hashable {
    /// Order-preserving deduplication, so question lists stay stable for the UI.
    func deduplicated() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
