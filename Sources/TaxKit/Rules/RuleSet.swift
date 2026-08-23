import Foundation

/// A code that no longer exists, and what replaced it. Codes are never deleted, so an
/// entry logged years ago still resolves to something the user can act on.
public struct Retirement: Codable, Hashable, Sendable {
    public let retired: ReliefCode
    public let supersededBy: ReliefCode?
    public let fromYA: Int
}

/// The complete rulebook for one Year of Assessment.
public struct RuleSet: Codable, Hashable, Sendable {
    public let yearOfAssessment: Int
    /// Bumped whenever the figures change within the same YA.
    public let revision: Int
    /// ISO date, `YYYY-MM-DD`, on which these figures were last checked against LHDN.
    public let verifiedOn: String
    public let sourceURL: URL
    public let brackets: BracketTable
    public let reliefs: [ReliefRule]
    public let retiredCodes: [Retirement]

    private enum CodingKeys: String, CodingKey {
        case yearOfAssessment, revision, verifiedOn, sourceURL, brackets, reliefs, retiredCodes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.yearOfAssessment = try c.decode(Int.self, forKey: .yearOfAssessment)
        self.revision = try c.decode(Int.self, forKey: .revision)
        self.verifiedOn = try c.decode(String.self, forKey: .verifiedOn)
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.brackets = try c.decode(BracketTable.self, forKey: .brackets)
        self.reliefs = try c.decode([ReliefRule].self, forKey: .reliefs)
        self.retiredCodes = try c.decodeIfPresent([Retirement].self, forKey: .retiredCodes) ?? []
    }

    /// Every relief including nested children, depth-first, parents before their children.
    public var allReliefs: [ReliefRule] {
        func flatten(_ rules: [ReliefRule]) -> [ReliefRule] {
            rules.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(reliefs)
    }

    public func relief(for code: ReliefCode) -> ReliefRule? {
        allReliefs.first { $0.code == code }
    }

    public var verifiedOnDate: Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: verifiedOn)
    }
}
