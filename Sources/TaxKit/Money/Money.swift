import Foundation

/// An exact amount of Malaysian ringgit, stored as a whole number of sen.
///
/// There is deliberately no `Double` arithmetic. Multiplying money by a rate goes
/// through `applying(_:rounding:)`; dividing money goes through `split`.
public struct Money: Hashable, Codable, Sendable, Comparable {

    /// The canonical value. RM 2,500.00 is 250_000 sen.
    public private(set) var sen: Int

    public static let zero = Money(sen: 0)

    public init(sen: Int) {
        self.sen = sen
    }

    /// Converts ringgit to sen, rounding half-up (ties away from zero).
    public init(ringgit: Decimal) {
        var scaled = ringgit * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        let number = NSDecimalNumber(decimal: rounded)
        precondition(
            number.compare(NSDecimalNumber(value: Int.max)) != .orderedDescending
                && number.compare(NSDecimalNumber(value: Int.min)) != .orderedAscending,
            "Money out of representable range: \(ringgit)"
        )
        self.sen = number.intValue
    }

    public static func + (lhs: Money, rhs: Money) -> Money {
        let (result, overflow) = lhs.sen.addingReportingOverflow(rhs.sen)
        precondition(!overflow, "Money addition overflowed")
        return Money(sen: result)
    }

    public static func - (lhs: Money, rhs: Money) -> Money {
        let (result, overflow) = lhs.sen.subtractingReportingOverflow(rhs.sen)
        precondition(!overflow, "Money subtraction overflowed")
        return Money(sen: result)
    }

    public static func < (lhs: Money, rhs: Money) -> Bool { lhs.sen < rhs.sen }

    /// Returns `self` if it is at or below `cap`, otherwise `cap`.
    /// Values below zero are returned unchanged — clamping is an upper bound only.
    public func clamped(to cap: Money) -> Money {
        sen > cap.sen ? cap : self
    }

    /// Charting only. Named to discourage use; never appears in a calculation path.
    public var lossyDoubleForCharting: Double { Double(sen) / 100 }

    /// Multiplies by a rate expressed as a fraction — pass `0.19` for 19%.
    ///
    /// This is the only way to apply a percentage to money. There is no
    /// `Money * Money`, because multiplying two amounts is never meaningful here.
    public func applying(_ rate: Decimal, rounding: RoundingRule = .halfUp) -> Money {
        var product = Decimal(sen) * rate
        var rounded = Decimal()
        NSDecimalRound(&rounded, &product, 0, rounding.nsMode)
        return Money(sen: NSDecimalNumber(decimal: rounded).intValue)
    }
}
