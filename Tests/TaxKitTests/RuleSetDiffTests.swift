import Testing
import Foundation
@testable import TaxKit

@Suite("Loading and diffing") struct RuleSetDiffTests {

    let loader = BundledRuleSetLoader()

    @Test("the bundled loader lists and loads every shipped year")
    func loaderLists() throws {
        #expect(loader.availableYears == [2023, 2024, 2025])
        #expect(try loader.ruleSet(for: 2024).yearOfAssessment == 2024)
    }

    @Test("an unshipped year throws rather than returning a wrong ruleset")
    func unknownYearThrows() {
        #expect(throws: RuleSetLoadingError.self) { try loader.ruleSet(for: 1999) }
    }

    @Test("the YA2024 to YA2025 diff reports every published change")
    func diff2024to2025() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2024),
                          to: try loader.ruleSet(for: 2025))

        func capChange(_ code: String) -> (from: Money, to: Money)? {
            for case .capChanged(let c, _, let from, let to) in deltas
            where c == ReliefCode(code) { return (from, to) }
            return nil
        }

        #expect(capChange("DISABLED_SELF")?.to == Money(ringgit: 7000))
        #expect(capChange("DISABLED_SPOUSE")?.to == Money(ringgit: 6000))
        #expect(capChange("CHILD_DISABLED")?.to == Money(ringgit: 8000))
        #expect(capChange("MEDICAL_LEARNDIS")?.to == Money(ringgit: 6000))
        #expect(capChange("INSURANCE_EDU_MEDICAL")?.to == Money(ringgit: 4000))

        let added = deltas.compactMap { delta -> ReliefCode? in
            if case .added(let code, _, _) = delta { return code }
            return nil
        }
        #expect(added == [ReliefCode("HOUSING_LOAN_INTEREST")])
    }

    @Test("the YA2023 to YA2024 diff reports the two sub-limits that appear")
    func diff2023to2024() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2023),
                          to: try loader.ruleSet(for: 2024))
        let added = Set(deltas.compactMap { delta -> ReliefCode? in
            if case .added(let code, _, _) = delta { return code }
            return nil
        })
        #expect(added == [ReliefCode("MEDICAL_DENTAL"), ReliefCode("PARENTS_CHECKUP")])
    }

    @Test("a removed relief reports its successor when one is declared")
    func removalReportsSuccessor() throws {
        let deltas = diff(from: try loader.ruleSet(for: 2025),
                          to: try loader.ruleSet(for: 2024))
        let removed = deltas.compactMap { delta -> ReliefCode? in
            if case .removed(let code, _, _) = delta { return code }
            return nil
        }
        #expect(removed == [ReliefCode("HOUSING_LOAN_INTEREST")])
    }

    @Test("diffing a ruleset against itself yields nothing")
    func selfDiffIsEmpty() throws {
        #expect(diff(from: try loader.ruleSet(for: 2025),
                     to: try loader.ruleSet(for: 2025)).isEmpty)
    }

    @Test("lines with equal magnitude are ordered deterministically")
    func tiesAreBrokenByCode() throws {
        // DISABLED_SELF and DISABLED_SPOUSE both rose by exactly RM 1,000 in YA2025,
        // so an OKU household produces two lines of identical magnitude.
        var year = Fixture.year(2025, gross: Money(ringgit: 110_000))
        year.selfIsDisabled = true
        year.spouseIsDisabled = true
        year.maritalStatus = .married

        func order() throws -> [String] {
            counterfactual(entries: [],
                           year: year,
                           under: try loader.ruleSet(for: 2025),
                           versus: try loader.ruleSet(for: 2024))
                .lines.map(\.code.rawValue)
        }
        let first = try order()
        #expect(try order() == first, "ordering must be reproducible")

        let tied = first.filter {
            $0 == "DISABLED_SELF" || $0 == "DISABLED_SPOUSE"
        }
        #expect(tied == ["DISABLED_SELF", "DISABLED_SPOUSE"],
                "equal magnitudes must fall back to code order")
    }

    @Test("an unshipped year throws the specific noRulesForYear case")
    func unknownYearThrowsSpecificCase() {
        #expect(throws: RuleSetLoadingError.noRulesForYear(1999)) {
            try loader.ruleSet(for: 1999)
        }
    }

    @Test("the counterfactual prices this year's spending under last year's rules")
    func counterfactualPricesTheChange() throws {
        var year = Fixture.year(2025, gross: Money(ringgit: 110_000))
        year.spouseHasIncome = false
        let entries = [Fixture.entry(ReliefCode("INSURANCE_EDU_MEDICAL"), 4000)]

        let result = counterfactual(entries: entries,
                                    year: year,
                                    under: try loader.ruleSet(for: 2025),
                                    versus: try loader.ruleSet(for: 2024))

        #expect(result.baselineYA == 2025)
        #expect(result.comparisonYA == 2024)

        let line = try #require(
            result.lines.first { $0.code == ReliefCode("INSURANCE_EDU_MEDICAL") })
        #expect(line.allowedUnderBaseline == Money(ringgit: 4000))
        #expect(line.allowedUnderComparison == Money(ringgit: 3000))
        #expect(line.difference == Money(ringgit: 1000))
    }

    @Test("unchanged reliefs do not clutter the counterfactual")
    func counterfactualOmitsUnchanged() throws {
        let result = counterfactual(entries: [Fixture.entry(.lifestyle, 500)],
                                    year: Fixture.year(2025),
                                    under: try loader.ruleSet(for: 2025),
                                    versus: try loader.ruleSet(for: 2024))
        #expect(result.lines.contains { $0.code == .lifestyle } == false)
    }

    @Test("the total does not double-count a sub-limit that also appears as a line")
    func totalExcludesNestedLines() throws {
        // MEDICAL_LEARNDIS is a child of MEDICAL_SERIOUS and rose RM4,000 -> RM6,000
        // in YA2025, so it produces both a parent line and a child line.
        let entries = [Fixture.entry(ReliefCode("MEDICAL_LEARNDIS"), 6000)]
        let result = counterfactual(entries: entries,
                                    year: Fixture.year(2025, gross: Money(ringgit: 110_000)),
                                    under: try loader.ruleSet(for: 2025),
                                    versus: try loader.ruleSet(for: 2024))

        let naive = result.lines.reduce(Money.zero) { $0 + $1.difference }
        #expect(result.totalReliefDifference == Money(ringgit: 2000))
        #expect(naive == Money(ringgit: 4000), "the lines really do double-count")
        #expect(result.totalReliefDifference < naive)
    }
}
