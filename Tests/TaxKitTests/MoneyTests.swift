import Testing
import Foundation
@testable import TaxKit

@Suite("Money") struct MoneyTests {

    @Test("sen is the canonical representation")
    func senIsCanonical() {
        #expect(Money(sen: 250_000).sen == 250_000)
        #expect(Money.zero.sen == 0)
    }

    @Test("ringgit initialiser rounds half-up to whole sen")
    func ringgitRoundsHalfUp() {
        #expect(Money(ringgit: Decimal(string: "2500.00")!).sen == 250_000)
        #expect(Money(ringgit: Decimal(string: "0.005")!).sen == 1)
        #expect(Money(ringgit: Decimal(string: "0.004")!).sen == 0)
        #expect(Money(ringgit: Decimal(string: "-0.005")!).sen == -1)
    }

    @Test("addition and subtraction are exact")
    func arithmeticIsExact() {
        let a = Money(ringgit: Decimal(string: "0.10")!)
        let b = Money(ringgit: Decimal(string: "0.20")!)
        #expect((a + b).sen == 30)          // the classic 0.1 + 0.2 Double failure
        #expect((a + b - b) == a)
    }

    @Test("comparison orders by sen")
    func comparisonOrders() {
        #expect(Money(sen: 100) < Money(sen: 101))
        #expect(Money(sen: -1) < Money.zero)
    }

    @Test("clamped never exceeds the cap and never invents value")
    func clampedBounds() {
        let cap = Money(sen: 250_000)
        #expect(Money(sen: 300_000).clamped(to: cap) == cap)
        #expect(Money(sen: 100_000).clamped(to: cap).sen == 100_000)
        #expect(Money(sen: -5).clamped(to: cap).sen == -5)
    }

    @Test("Codable round-trips")
    func codableRoundTrip() throws {
        let original = Money(sen: 123_456)
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(Money.self, from: data) == original)
    }
}

@Suite("Money.applying") struct MoneyRateTests {

    @Test("applies a fractional rate and rounds half-up by default")
    func appliesRate() {
        // RM 800.00 at 19% is RM 152.00 exactly.
        #expect(Money(sen: 80_000).applying(Decimal(string: "0.19")!).sen == 15_200)
    }

    @Test("half-up is the default at an exact .5 sen boundary")
    func halfUpAtBoundary() {
        // 1 sen at 50% is 0.5 sen, which rounds up to 1.
        #expect(Money(sen: 1).applying(Decimal(string: "0.5")!).sen == 1)
        // 3 sen at 50% is 1.5 sen, which rounds up to 2.
        #expect(Money(sen: 3).applying(Decimal(string: "0.5")!).sen == 2)
    }

    @Test("explicit rounding rules override the default")
    func explicitRounding() {
        let one = Money(sen: 1)
        let half = Decimal(string: "0.5")!
        #expect(one.applying(half, rounding: .down).sen == 0)
        #expect(one.applying(half, rounding: .up).sen == 1)
        #expect(one.applying(half, rounding: .bankers).sen == 0)   // ties to even
        #expect(Money(sen: 3).applying(half, rounding: .bankers).sen == 2)
    }

    @Test("negative amounts round away from zero under half-up")
    func negativeHalfUp() {
        #expect(Money(sen: -1).applying(Decimal(string: "0.5")!).sen == -1)
    }

    @Test("a zero rate yields zero and a rate of one is the identity")
    func degenerateRates() {
        let m = Money(sen: 123_456)
        #expect(m.applying(Decimal(0)) == .zero)
        #expect(m.applying(Decimal(1)) == m)
    }
}
