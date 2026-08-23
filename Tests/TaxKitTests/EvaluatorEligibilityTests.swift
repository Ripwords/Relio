import Testing
import Foundation
@testable import TaxKit

@Suite("Evaluator — eligibility and requirements") struct EvaluatorEligibilityTests {

    @Test("an unanswered question yields needsInfo, never ineligible")
    func unansweredQuestion() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        let spouse = try #require(result.assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .needsInfo(let questions) = spouse.eligibility else {
            Issue.record("expected .needsInfo, got \(spouse.eligibility)"); return
        }
        #expect(questions.contains(.spouseHasIncome))
        // The cap is still shown, so the UI can say "unlock RM 4,000".
        #expect(spouse.cap == Money(ringgit: 4000))
    }

    @Test("answering the question makes the relief eligible")
    func answeredQuestion() throws {
        var year = Fixture.year()
        year.spouseHasIncome = false
        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.assessment(for: ReliefCode("SPOUSE_ALIMONY"))?.eligibility == .eligible)
    }

    @Test("a definitively failing condition is ineligible with a readable reason")
    func failingCondition() throws {
        var year = Fixture.year()
        year.spouseHasIncome = true
        year.assessmentType = .separate
        year.maritalStatus = .married   // closes the alimony branch too
        let spouse = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .ineligible(let reasons) = spouse.eligibility else {
            Issue.record("expected .ineligible, got \(spouse.eligibility)"); return
        }
        #expect(reasons.isEmpty == false)
    }

    @Test("a relief outside its year range is ineligible, not merely absent")
    func outsideYearRange() throws {
        // HOUSING_LOAN_INTEREST is yaRange 2025-2027 and exists only in ya-2025.json,
        // so evaluating YA2025's rules against a 2028 snapshot must refuse it.
        var year = Fixture.year()
        year.year = 2028
        year.propertyPriceSen = Money(ringgit: 400_000).sen
        let housing = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        guard case .ineligible = housing.eligibility else {
            Issue.record("expected .ineligible, got \(housing.eligibility)"); return
        }
    }

    @Test("a claim with every required document passes its checks")
    func requirementsSatisfied() throws {
        let entry = Fixture.entry(ReliefCode("MEDICAL_SERIOUS"), 3000,
                                  documents: [.officialReceipt, .medicalCertificate])
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [entry])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        #expect(medical.requirements.count == 2)
        #expect(medical.requirements.allSatisfy { $0.isSatisfied })
    }

    @Test("a missing document names the kind and the entries that lack it")
    func requirementMissing() throws {
        let entry = Fixture.entry(ReliefCode("MEDICAL_SERIOUS"), 3000,
                                  documents: [.officialReceipt])
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [entry])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        let failure = try #require(medical.requirements.first { !$0.isSatisfied })
        #expect(failure.kind == .medicalCertificate)
        #expect(failure.status == .missing(entryIDs: [entry.id]))
    }

    @Test("a relief with no entries has no requirement failures")
    func noEntriesNoFailures() throws {
        let medical = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("MEDICAL_SERIOUS")))
        #expect(medical.requirements.allSatisfy { $0.isSatisfied })
    }

    @Test("one dependent's missing details do not withhold another's relief")
    func partialDependentFactsStillGrant() throws {
        // A parent records two children but has not entered a birth date for one.
        let known = DependentSnapshot(name: "Aisyah", ageAtYearEnd: 7)
        let vague = DependentSnapshot(name: "Unknown", ageAtYearEnd: nil)
        let result = evaluate(ruleSet: try Fixture.rules(),
                              year: Fixture.year(dependents: [known, vague]),
                              entries: [])

        let child = try #require(result.assessment(for: ReliefCode("CHILD_UNDER_18")))
        // The RM 2,000 earned by the known child is granted...
        #expect(child.cap == Money(ringgit: 2000))
        #expect(child.allowed == Money(ringgit: 2000))
        // ...and the app still asks about the other one.
        guard case .needsInfo(let questions) = child.eligibility else {
            Issue.record("expected .needsInfo alongside the grant, got \(child.eligibility)")
            return
        }
        #expect(questions.contains(.dependentDetails))
    }

    @Test("a fixed automatic relief is NOT granted while its own question is open")
    func fixedAutomaticWaitsForItsAnswer() throws {
        // Contrast with the per-dependent case above: granting this without knowing
        // whether the taxpayer is registered disabled would overstate relief.
        let disabled = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("DISABLED_SELF")))
        guard case .needsInfo = disabled.eligibility else {
            Issue.record("expected .needsInfo, got \(disabled.eligibility)"); return
        }
        #expect(disabled.allowed == .zero)
        #expect(disabled.headroom == Money(ringgit: 7000))
    }

    @Test("cap questions and predicate questions merge into one needsInfo list")
    func questionsMerge() throws {
        let housing = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("HOUSING_LOAN_INTEREST")))
        guard case .needsInfo(let questions) = housing.eligibility else {
            Issue.record("expected .needsInfo, got \(housing.eligibility)"); return
        }
        #expect(questions == [.propertyPrice])
    }

    @Test("an ineligible relief with entries allows nothing and does not cut tax")
    func ineligibleReliefAllowsNothing() throws {
        // A male taxpayer logging breastfeeding-equipment expenses: the gender
        // predicate fails outright, so none of it is claimable.
        var year = Fixture.year(gross: Money(ringgit: 110_000))
        year.gender = .male
        let entry = Fixture.entry(ReliefCode("BREASTFEEDING"), 900)

        let result = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [entry])
        let relief = try #require(result.assessment(for: ReliefCode("BREASTFEEDING")))

        guard case .ineligible = relief.eligibility else {
            Issue.record("expected .ineligible, got \(relief.eligibility)"); return
        }
        #expect(relief.claimed == Money(ringgit: 900))   // still shown to the user
        #expect(relief.allowed == .zero)                 // but not claimable
        #expect(relief.taxSaved == nil)

        // And it must not have quietly reduced the tax bill.
        let baseline = evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
        #expect(result.chargeableIncome == baseline.chargeableIncome)
        #expect(result.estimatedTax == baseline.estimatedTax)
    }

    @Test("a needsInfo relief with entries is still claimable")
    func needsInfoReliefStillAllows() throws {
        // Contrast: an unanswered question must not behave like a refusal.
        let result = evaluate(
            ruleSet: try Fixture.rules(),
            year: Fixture.year(gross: Money(ringgit: 110_000)),
            entries: [Fixture.entry(ReliefCode("SPOUSE_ALIMONY"), 4000)])
        let relief = try #require(result.assessment(for: ReliefCode("SPOUSE_ALIMONY")))
        guard case .needsInfo = relief.eligibility else {
            Issue.record("expected .needsInfo, got \(relief.eligibility)"); return
        }
        #expect(relief.allowed == Money(ringgit: 4000))
    }

    @Test("a recorded prior claim resolves a frequency-limited relief")
    func claimHistoryResolvesFrequency() throws {
        // Breastfeeding equipment is claimable once every two years of assessment.
        var year = Fixture.year()
        year.gender = .female
        year.dependents = [DependentSnapshot(name: "Baby", ageAtYearEnd: 1)]

        year.lastClaimedYear = [ReliefCode("BREASTFEEDING"): 2024]
        let tooSoon = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("BREASTFEEDING")))
        guard case .ineligible = tooSoon.eligibility else {
            Issue.record("claimed last year — expected .ineligible, got \(tooSoon.eligibility)")
            return
        }

        year.lastClaimedYear = [ReliefCode("BREASTFEEDING"): 2023]
        let longEnough = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: year, entries: [])
                .assessment(for: ReliefCode("BREASTFEEDING")))
        #expect(longEnough.eligibility == .eligible)
    }
}
