import Testing
import Foundation
@testable import TaxKit

@Suite("Evaluator — cap kinds") struct EvaluatorCapKindTests {

    static func child(age: Int, percent: Int = 100,
                      education: EducationLevel? = nil,
                      disabled: Bool = false) -> DependentSnapshot {
        DependentSnapshot(name: "Child \(age)", ageAtYearEnd: age,
                          educationLevel: education, isDisabled: disabled,
                          claimPercentage: percent)
    }

    @Test("per-dependent cap multiplies by the number of qualifying dependents")
    func perDependentMultiplies() throws {
        let year = Fixture.year(dependents: [Self.child(age: 5), Self.child(age: 10), Self.child(age: 16)])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 6000))
    }

    @Test("a 50% split halves that dependent's share only")
    func splitClaim() throws {
        let year = Fixture.year(dependents: [Self.child(age: 5), Self.child(age: 10, percent: 50)])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 3000))
    }

    @Test("dependents who fail the rule's own predicate do not count")
    func nonQualifyingDependentsExcluded() throws {
        // An 18-year-old is not "under 18"; a tertiary student is not pre-tertiary.
        let year = Fixture.year(dependents: [
            Self.child(age: 5),
            Self.child(age: 18, education: .tertiaryLocal)
        ])
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap
                == Money(ringgit: 2000))
        #expect(result.assessment(for: ReliefCode("CHILD_TERTIARY"))?.cap
                == Money(ringgit: 8000))
        #expect(result.assessment(for: ReliefCode("CHILD_PRE_TERTIARY"))?.cap == .zero)
    }

    @Test("no dependents means a zero cap, not the per-child amount")
    func noDependents() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        #expect(result.assessment(for: ReliefCode("CHILD_UNDER_18"))?.cap == .zero)
    }

    @Test("tiered cap selects the tier the property price falls in")
    func tieredSelection() throws {
        var cheap = Fixture.year()
        cheap.propertyPriceSen = Money(ringgit: 450_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: cheap, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7000))

        var mid = Fixture.year()
        mid.propertyPriceSen = Money(ringgit: 600_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: mid, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 5000))
    }

    @Test("a price above every tier gives no relief")
    func aboveEveryTier() throws {
        var expensive = Fixture.year()
        expensive.propertyPriceSen = Money(ringgit: 900_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: expensive, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap == .zero)
    }

    @Test("an unknown tier fact shows the best case and asks the question")
    func unknownTierFact() throws {
        let assessment = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        #expect(assessment.cap == Money(ringgit: 7000))
        #expect(assessment.eligibility == .needsInfo(questions: [.propertyPrice]))
    }

    @Test("a boundary price lands in the lower tier")
    func tierBoundary() throws {
        var exact = Fixture.year()
        exact.propertyPriceSen = Money(ringgit: 500_000).sen
        #expect(evaluate(ruleSet: try Fixture.rules(), year: exact, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7000))
    }
}
