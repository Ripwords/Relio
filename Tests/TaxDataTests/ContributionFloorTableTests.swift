import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Contribution floor table") struct ContributionFloorTableTests {

    static let anySource = URL(string: "https://example.invalid/schedule")!

    static func rate(_ numerator: Int, per denominator: Int,
                     atOrAbove: Money = Money(sen: 1)) -> ContributionFloorTable {
        ContributionFloorTable(
            basis: .flatRate(Decimal(numerator) / Decimal(denominator),
                             appliesAtOrAbove: atOrAbove),
            effectiveFrom: WageMonth(year: 2022, month: 7),
            sourceURL: anySource)
    }

    static func ladder(_ rungs: [(Int, Int)]) -> ContributionFloorTable {
        ContributionFloorTable(
            basis: .stepLadder(rungs.map {
                .init(monthlyWageAtLeast: Money(sen: $0.0), employeeFloor: Money(sen: $0.1))
            }),
            effectiveFrom: WageMonth(year: 2022, month: 9),
            effectiveThrough: WageMonth(year: 2024, month: 9),
            sourceURL: anySource)
    }

    @Test("a flat rate rounds down, so the figure never climbs past the truth")
    func flatRateRoundsDown() {
        // 11% of RM1,234.56 is RM135.8016. Half-up would report 135.80, which is above
        // 135.8016 rounded to the sen only by luck; rounding down is the direction the
        // guarantee needs and it never depends on luck.
        #expect(Self.rate(11, per: 100).employeeFloor(forMonthlyWage: Money(sen: 123_456))
                == Money(sen: 13_580))
        #expect(Self.rate(11, per: 100).employeeFloor(forMonthlyWage: Money(sen: 880_000))
                == Money(sen: 96_800))
    }

    @Test("a flat rate proves nothing below the wage it starts at")
    func flatRateHasAFloorOfItsOwn() {
        let table = Self.rate(11, per: 100, atOrAbove: Money(sen: 1001))
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 1000)) == .zero)
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 1001)) == Money(sen: 110))
    }

    @Test("a wage reads its own band's rung, never the next band's")
    func ladderReadsTheBandBelow() {
        // The trap the whole ladder exists to avoid. Rungs are keyed on each band's
        // inclusive lower limit, so RM50.00 is still in the band that runs to RM50 and
        // must not pick up the rung that starts at RM50.01.
        let table = Self.ladder([(1, 0), (3001, 30), (5001, 45)])
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 3000)) == .zero)
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 3001)) == Money(sen: 30))
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 5000)) == Money(sen: 30))
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 5001)) == Money(sen: 45))
    }

    @Test("the highest rung holds at every wage above it")
    func ladderTopRungIsACeiling() {
        // The insured wage is capped, so the top band's published amount is the answer for
        // every higher wage rather than the start of an extrapolation.
        let table = Self.ladder([(1, 0), (3001, 30), (5001, 45)])
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 1_000_000)) == Money(sen: 45))
    }

    @Test("an unmatched wage is a floor of nothing, not an error")
    func totalOverEveryWage() {
        let table = Self.ladder([(3001, 30)])
        #expect(table.employeeFloor(forMonthlyWage: .zero) == .zero)
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: 3000)) == .zero)
        // A negative wage cannot arise from the derivation, but the lookup is total.
        #expect(table.employeeFloor(forMonthlyWage: Money(sen: -500)) == .zero)
    }

    @Test("the table that proves nothing proves nothing at any wage")
    func provesNothingIsZeroEverywhere() {
        for sen in [0, 1, 100_000, 600_000, 10_000_000] {
            #expect(ContributionFloorTable.provesNothing
                        .employeeFloor(forMonthlyWage: Money(sen: sen)) == .zero)
        }
        #expect(ContributionFloorTable.provesNothing.sourceURL == nil)
    }

    @Test("an era covers its first and last month and nothing outside them")
    func eraBoundaries() {
        let table = Self.ladder([(1, 0)])
        #expect(!table.covers(WageMonth(year: 2022, month: 8)))
        #expect(table.covers(WageMonth(year: 2022, month: 9)))
        #expect(table.covers(WageMonth(year: 2024, month: 9)))
        #expect(!table.covers(WageMonth(year: 2024, month: 10)))

        let open = Self.rate(11, per: 100)
        #expect(!open.covers(WageMonth(year: 2022, month: 6)))
        #expect(open.covers(WageMonth(year: 2999, month: 12)))
    }
}
