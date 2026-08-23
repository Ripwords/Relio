import Foundation

/// One income band. `cumulativeBase` is the total tax owed at exactly `lowerBound`,
/// taken verbatim from LHDN's published table rather than derived, so bracket tax is a
/// lookup plus one multiplication with no accumulated rounding error.
public struct Band: Codable, Hashable, Sendable {
    /// The income already taxed by the lower bands — LHDN's "the first 5,000".
    /// The rate applies to `chargeable - lowerBound`, so widths are clean ringgit
    /// amounts and no band is a sen too narrow.
    public let lowerBound: Money
    /// Inclusive. `nil` for the top band.
    public let upperBound: Money?
    /// A fraction: 19% is `0.19`. Decoded from a string to avoid Double.
    public let rate: Decimal
    public let cumulativeBase: Money

    public init(lowerBound: Money, upperBound: Money?, rate: Decimal, cumulativeBase: Money) {
        self.lowerBound = lowerBound
        self.upperBound = upperBound
        self.rate = rate
        self.cumulativeBase = cumulativeBase
    }

    private enum CodingKeys: String, CodingKey { case lowerSen, upperSen, rate, cumulativeBaseSen }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.lowerBound = Money(sen: try c.decode(Int.self, forKey: .lowerSen))
        self.upperBound = try c.decodeIfPresent(Int.self, forKey: .upperSen).map(Money.init(sen:))
        self.cumulativeBase = Money(sen: try c.decode(Int.self, forKey: .cumulativeBaseSen))

        let raw = try c.decode(String.self, forKey: .rate)
        guard let rate = Decimal(string: raw) else {
            throw DecodingError.dataCorruptedError(
                forKey: .rate, in: c, debugDescription: "Rate '\(raw)' is not a decimal")
        }
        self.rate = rate
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(lowerBound.sen, forKey: .lowerSen)
        try c.encodeIfPresent(upperBound?.sen, forKey: .upperSen)
        try c.encode("\(rate)", forKey: .rate)
        try c.encode(cumulativeBase.sen, forKey: .cumulativeBaseSen)
    }
}

/// The income tax bands for one Year of Assessment. Behaviour is added in Task 10.
public struct BracketTable: Codable, Hashable, Sendable {
    public let bands: [Band]

    public init(bands: [Band]) { self.bands = bands }
}
