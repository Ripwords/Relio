import Testing
import Foundation
@testable import TaxKit

@Suite("Bracket maths") struct BracketTableTests {

    static func table() throws -> BracketTable {
        try RulebookIntegrityTests.load(2025).brackets
    }

    @Test("tax is zero up to the end of the first band")
    func zeroBand() throws {
        let t = try Self.table()
        #expect(t.tax(on: .zero) == .zero)
        #expect(t.tax(on: Money(ringgit: 5000)) == .zero)
    }

    @Test("tax matches LHDN's published cumulative figures at every band boundary")
    func boundariesMatchPublishedTable() throws {
        let t = try Self.table()
        let published: [(ringgit: Int, tax: Int)] = [
            (5_000, 0), (20_000, 150), (35_000, 600), (50_000, 1_500),
            (70_000, 3_700), (100_000, 9_400), (400_000, 84_400),
            (600_000, 136_400), (2_000_000, 528_400)
        ]
        for row in published {
            #expect(t.tax(on: Money(ringgit: Decimal(row.ringgit)))
                    == Money(ringgit: Decimal(row.tax)),
                    "chargeable RM \(row.ringgit)")
        }
    }

    @Test("tax one ringgit either side of a boundary moves by the right rate")
    func nearBoundaries() throws {
        let t = try Self.table()
        // RM 70,001 is the first ringgit taxed at 19%.
        #expect(t.tax(on: Money(ringgit: 70_001)) == Money(ringgit: Decimal(string: "3700.19")!))
        // RM 69,999 is still in the 11% band: 1,500 + 19,999 x 0.11 = 3,699.89
        #expect(t.tax(on: Money(ringgit: 69_999)) == Money(ringgit: Decimal(string: "3699.89")!))
    }

    @Test("the worked example from the spec")
    func specExample() throws {
        let t = try Self.table()
        // Chargeable RM 92,400: 3,700 + (92,400 - 70,000) x 0.19 = 3,700 + 4,256 = 7,956
        #expect(t.tax(on: Money(ringgit: 92_400)) == Money(ringgit: 7_956))
        #expect(t.marginalRate(at: Money(ringgit: 92_400)) == Decimal(string: "0.19")!)
    }

    @Test("the top band is open-ended")
    func topBand() throws {
        let t = try Self.table()
        // 528,400 + 1,000,000 x 0.30 = 828,400
        #expect(t.tax(on: Money(ringgit: 3_000_000)) == Money(ringgit: 828_400))
        #expect(t.marginalRate(at: Money(ringgit: 9_999_999)) == Decimal(string: "0.30")!)
    }

    @Test("tax saved is the real difference, not relief times the marginal rate")
    func taxSavedStraddlingABoundary() throws {
        let t = try Self.table()
        // Chargeable 71,000 reduced by 3,000 lands at 68,000, crossing the 19%/11% edge.
        let chargeable = Money(ringgit: 71_000)
        let relief = Money(ringgit: 3_000)
        let saved = t.taxSaved(reducing: chargeable, by: relief)

        #expect(saved == t.tax(on: chargeable) - t.tax(on: Money(ringgit: 68_000)))
        // The single-rate shortcut would say 3,000 x 0.19 = 570. The truth is less.
        #expect(saved < relief.applying(Decimal(string: "0.19")!))
        // 3,890 - 3,480 = 410
        #expect(saved == Money(ringgit: 410))
    }

    @Test("tax saved within one band equals relief times that band's rate")
    func taxSavedWithinOneBand() throws {
        let t = try Self.table()
        let saved = t.taxSaved(reducing: Money(ringgit: 92_400), by: Money(ringgit: 800))
        #expect(saved == Money(ringgit: 152))
    }

    @Test("relief larger than chargeable income cannot save more than the tax owed")
    func reliefExceedsIncome() throws {
        let t = try Self.table()
        let chargeable = Money(ringgit: 30_000)
        #expect(t.taxSaved(reducing: chargeable, by: Money(ringgit: 90_000))
                == t.tax(on: chargeable))
    }

    @Test("negative chargeable income is treated as zero")
    func negativeIncome() throws {
        let t = try Self.table()
        #expect(t.tax(on: Money(sen: -5_000)) == .zero)
    }

    @Test("a negative relief saves nothing rather than adding tax")
    func negativeReliefSavesNothing() throws {
        let t = try Self.table()
        // SSPN is a net deposit, so a withdrawal-heavy year really can be negative.
        #expect(t.taxSaved(reducing: Money(ringgit: 92_400),
                           by: Money(ringgit: -2_000)) == .zero)
    }
}
