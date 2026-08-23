import Foundation

/// The fact a tiered cap is selected by.
public enum TieredFact: String, Codable, Hashable, Sendable {
    /// Purchase price of the residence, for housing loan interest relief.
    case propertyPrice
}

/// One step of a tiered cap. `maxSen` is the inclusive upper bound of the selecting
/// fact; `nil` means "and above".
public struct Tier: Codable, Hashable, Sendable {
    public let maxSen: Int?
    public let amount: Money

    public init(maxSen: Int?, amount: Money) {
        self.maxSen = maxSen
        self.amount = amount
    }

    private enum CodingKeys: String, CodingKey { case maxSen, sen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.maxSen = try c.decodeIfPresent(Int.self, forKey: .maxSen)
        self.amount = Money(sen: try c.decode(Int.self, forKey: .sen))
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(maxSen, forKey: .maxSen)
        try c.encode(amount.sen, forKey: .sen)
    }
}

/// How much of a relief may be claimed.
public enum Cap: Codable, Hashable, Sendable {
    /// A flat ceiling.
    case fixed(Money)
    /// A ceiling that applies once per eligible dependent.
    case perDependent(Money)
    /// A ceiling selected by a fact about the claim.
    case tiered(on: TieredFact, tiers: [Tier])

    private enum CodingKeys: String, CodingKey { case kind, sen, on, tiers }
    private enum Kind: String, Codable { case fixed, perDependent, tiered }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .fixed:
            self = .fixed(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .perDependent:
            self = .perDependent(Money(sen: try c.decode(Int.self, forKey: .sen)))
        case .tiered:
            self = .tiered(on: try c.decode(TieredFact.self, forKey: .on),
                           tiers: try c.decode([Tier].self, forKey: .tiers))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fixed(let amount):
            try c.encode(Kind.fixed, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .perDependent(let amount):
            try c.encode(Kind.perDependent, forKey: .kind)
            try c.encode(amount.sen, forKey: .sen)
        case .tiered(let fact, let tiers):
            try c.encode(Kind.tiered, forKey: .kind)
            try c.encode(fact, forKey: .on)
            try c.encode(tiers, forKey: .tiers)
        }
    }

    /// The largest amount this cap can ever allow, ignoring per-dependent multiplicity.
    /// Used for display and for ordering opportunities.
    public var nominalCeiling: Money {
        switch self {
        case .fixed(let amount), .perDependent(let amount):
            return amount
        case .tiered(_, let tiers):
            return tiers.map(\.amount).max() ?? .zero
        }
    }
}
