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
