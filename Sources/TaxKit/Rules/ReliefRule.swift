import Foundation

/// One relief category, optionally containing sub-limits that draw on its own ceiling.
public struct ReliefRule: Codable, Hashable, Sendable {
    public let code: ReliefCode
    public let name: String
    public let cap: Cap
    /// Granted in full when eligible, with no entry and no receipt — LHDN gives every
    /// resident the RM 9,000 individual relief, and child and spouse reliefs follow from
    /// the household rather than from a purchase.
    public let automatic: Bool
    public let requiredDocuments: [DocumentKind]
    public let eligibility: EligibilityPredicate?
    /// Sub-limits. A child's claims also count against this relief's cap.
    public let children: [ReliefRule]
    public let sourceURL: URL
    /// Set when a figure could not be verified against hasil.gov.my. Excluded from
    /// tax-saved maths and rendered with a "verify with LHDN" note.
    public let unverified: Bool
    public let notes: String?

    private enum CodingKeys: String, CodingKey {
        case code, name, cap, automatic, requiredDocuments, eligibility, children, sourceURL, unverified, notes
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.code = try c.decode(ReliefCode.self, forKey: .code)
        self.name = try c.decode(String.self, forKey: .name)
        self.cap = try c.decode(Cap.self, forKey: .cap)
        self.automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        self.requiredDocuments = try c.decodeIfPresent([DocumentKind].self, forKey: .requiredDocuments) ?? []
        self.eligibility = try c.decodeIfPresent(EligibilityPredicate.self, forKey: .eligibility)
        self.children = try c.decodeIfPresent([ReliefRule].self, forKey: .children) ?? []
        self.sourceURL = try c.decode(URL.self, forKey: .sourceURL)
        self.unverified = try c.decodeIfPresent(Bool.self, forKey: .unverified) ?? false
        self.notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }
}
