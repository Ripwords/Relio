import Testing
import Foundation
@testable import TaxKit

@Suite("Tax saved") struct TaxSavedTests {

    /// Gross RM 110,000 with only the automatic RM 9,000 relief leaves RM 101,000
    /// chargeable — just inside the 25% band. Lifestyle headroom of RM 2,500 straddles
    /// the RM 100,000 boundary, which is exactly the case a marginal-rate shortcut gets
    /// wrong.
    static func year() -> TaxYearSnapshot {
        Fixture.year(gross: Money(ringgit: 110_000))
    }

    @Test("no income means no tax figures at all")
    func noIncome() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        #expect(result.chargeableIncome == nil)
        #expect(result.estimatedTax == nil)
        #expect(result.totalOpportunity == nil)
        #expect(result.assessment(for: .lifestyle)?.taxSaved == nil)
    }

    @Test("chargeable income is gross less every allowed relief")
    func chargeableIncome() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Self.year(), entries: [])
        // Only SELF_AND_DEPENDENTS (RM 9,000) is allowed with no entries.
        #expect(result.chargeableIncome == Money(ringgit: 101_000))
        #expect(result.estimatedTax == (try Fixture.rules().brackets
                                            .tax(on: Money(ringgit: 101_000))))
    }

    @Test("per-relief tax saved is the true difference across the boundary")
    func perReliefSaving() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Self.year(), entries: [])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        let expected = rules.brackets.taxSaved(reducing: Money(ringgit: 101_000),
                                               by: Money(ringgit: 2_500))
        #expect(lifestyle.taxSaved == expected)
        // 1,000 at 25% plus 1,500 at 19% = 250 + 285 = 535, not 2,500 x 25% = 625.
        #expect(expected == Money(ringgit: 535))
    }

    @Test("an ineligible relief has no saving")
    func ineligibleHasNoSaving() throws {
        var year = Self.year()
        year.spouseHasIncome = true
        year.assessmentType = .separate
        year.maritalStatus = .married
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        #expect(spouse.taxSaved == nil)
    }

    @Test("a needsInfo relief still shows what answering is worth")
    func needsInfoStillShowsValue() throws {
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Self.year(), entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .needsInfo = spouse.eligibility else {
            Issue.record("expected .needsInfo"); return
        }
        #expect(spouse.taxSaved != nil)
        #expect(spouse.taxSaved! > .zero)
    }

    @Test("a fully used relief has zero saving, not nil")
    func fullyUsedRelief() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Self.year(),
                              entries: [Fixture.entry(.lifestyle, 2500)])
        #expect(result.assessment(for: .lifestyle)?.headroom == .zero)
        #expect(result.assessment(for: .lifestyle)?.taxSaved == .zero)
    }

    @Test("total opportunity is one calculation, not a sum of the parts")
    func totalIsNotASum() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Self.year(), entries: [])
        let total = try #require(result.totalOpportunity)

        let naiveSum = result.assessments.compactMap(\.taxSaved).reduce(Money.zero, +)
        #expect(total < naiveSum, "summing per-relief figures double-counts the top band")

        let combinedHeadroom = result.assessments
            .filter { $0.taxSaved != nil }
            .reduce(Money.zero) { $0 + $1.headroom }
        #expect(total == rules.brackets.taxSaved(reducing: Money(ringgit: 101_000),
                                                 by: combinedHeadroom))
    }

    @Test("relief cannot save more tax than is owed")
    func cannotSaveMoreThanOwed() throws {
        let result = evaluate(ruleSet: try Fixture.rules(),
                              year: Fixture.year(gross: Money(ringgit: 20_000)),
                              entries: [])
        #expect(try #require(result.totalOpportunity) <= #require(result.estimatedTax))
    }
}
