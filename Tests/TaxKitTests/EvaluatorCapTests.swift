import Testing
import Foundation
@testable import TaxKit

/// Shared builders for the evaluator suites.
enum Fixture {
    static func year(_ ya: Int = 2025,
                     gross: Money? = nil,
                     dependents: [DependentSnapshot] = []) -> TaxYearSnapshot {
        var snapshot = TaxYearSnapshot(year: ya)
        snapshot.grossIncome = gross
        snapshot.dependents = dependents
        return snapshot
    }

    static func entry(_ code: ReliefCode,
                      _ ringgit: Decimal,
                      claimant: Claimant = .individual,
                      dependentID: UUID? = nil,
                      documents: Set<DocumentKind> = [.officialReceipt]) -> EntrySnapshot {
        EntrySnapshot(id: UUID(),
                      code: code,
                      amount: Money(ringgit: ringgit),
                      claimant: claimant,
                      dependentID: dependentID,
                      documentKinds: documents)
    }

    static func rules(_ ya: Int = 2025) throws -> RuleSet {
        try RulebookIntegrityTests.load(ya)
    }
}

@Suite("Evaluator — flat caps") struct EvaluatorCapTests {

    @Test("an unused relief reports its full cap as headroom")
    func unusedRelief() throws {
        let result = evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.cap == Money(ringgit: 2500))
        #expect(lifestyle.claimed == .zero)
        #expect(lifestyle.allowed == .zero)
        #expect(lifestyle.headroom == Money(ringgit: 2500))
    }

    @Test("claims accumulate and reduce headroom")
    func claimsAccumulate() throws {
        let result = evaluate(
            ruleSet: try Fixture.rules(),
            year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 1200), Fixture.entry(.lifestyle, 500)])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.claimed == Money(ringgit: 1700))
        #expect(lifestyle.allowed == Money(ringgit: 1700))
        #expect(lifestyle.headroom == Money(ringgit: 800))
    }

    @Test("over-claiming is capped and headroom never goes negative")
    func overClaiming() throws {
        let result = evaluate(
            ruleSet: try Fixture.rules(),
            year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 4000)])
        let lifestyle = try #require(result.assessment(for: .lifestyle))
        #expect(lifestyle.claimed == Money(ringgit: 4000))   // what the user entered
        #expect(lifestyle.allowed == Money(ringgit: 2500))   // what LHDN will allow
        #expect(lifestyle.headroom == .zero)
    }

    @Test("every relief in the ruleset appears in the result, claimed or not")
    func everyReliefAppears() throws {
        let rules = try Fixture.rules()
        let result = evaluate(ruleSet: rules, year: Fixture.year(), entries: [])
        let assessed = Set(result.allAssessments.map(\.code))
        #expect(assessed == Set(rules.allReliefs.map(\.code)))
    }

    @Test("assessments carry the rule's provenance through to the UI")
    func provenance() throws {
        let lifestyle = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: .lifestyle))
        #expect(lifestyle.name.contains("Lifestyle"))
        #expect(lifestyle.sourceURL.host()?.hasSuffix("hasil.gov.my") == true)
        #expect(lifestyle.unverified == false)
    }

    @Test("a code absent from this year surfaces as unresolved, never silently dropped")
    func unknownCodeSurfaces() throws {
        // HOUSING_LOAN_INTEREST does not exist in YA2024.
        let entry = Fixture.entry(ReliefCode("HOUSING_LOAN_INTEREST"), 3000)
        let result = evaluate(ruleSet: try Fixture.rules(2024),
                              year: Fixture.year(2024), entries: [entry])
        #expect(result.unresolved.count == 1)
        #expect(result.unresolved[0].entryID == entry.id)
        #expect(result.unresolved[0].reason == .unknownInThisYear)
    }

    @Test("a retired code resolves to its successor rather than vanishing")
    func retiredCodeSurfacesSuccessor() throws {
        var rules = try Fixture.rules()
        rules = try Self.withRetirement(rules, retired: "BOOKS", supersededBy: "LIFESTYLE")
        let entry = Fixture.entry(ReliefCode("BOOKS"), 120)
        let result = evaluate(ruleSet: rules, year: Fixture.year(), entries: [entry])
        #expect(result.unresolved.count == 1)
        #expect(result.unresolved[0].reason == .retired(supersededBy: .lifestyle))
        // The amount is NOT counted against Lifestyle — the user must confirm the move.
        #expect(result.assessment(for: .lifestyle)?.claimed == .zero)
    }

    /// Re-encodes a ruleset with an extra retirement, so the test does not depend on a
    /// retirement existing in the shipped rulebook.
    static func withRetirement(_ rules: RuleSet,
                               retired: String,
                               supersededBy: String) throws -> RuleSet {
        var object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(rules)) as! [String: Any]
        object["retiredCodes"] = [["retired": retired,
                                   "supersededBy": supersededBy,
                                   "fromYA": 2021]]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(RuleSet.self, from: data)
    }

    @Test("totals count the allowed amounts, not the claimed ones")
    func totals() throws {
        let rules = try Fixture.rules()
        // Measured as a delta against the no-entry baseline, so the automatic reliefs
        // (which are granted with no entry) do not make this assertion brittle.
        let baseline = evaluate(ruleSet: rules, year: Fixture.year(), entries: [])
        let withEntries = evaluate(
            ruleSet: rules, year: Fixture.year(),
            entries: [Fixture.entry(.lifestyle, 4000), Fixture.entry(ReliefCode("SSPN"), 1000)])
        // Lifestyle is capped at 2,500 despite the 4,000 claim, plus 1,000 of SSPN.
        #expect(withEntries.totalAllowed - baseline.totalAllowed == Money(ringgit: 3500))
    }

    @Test("a negative net claim yields zero allowed, never headroom above the cap")
    func negativeClaimIsFloored() throws {
        // SSPN is a net deposit: withdrawals can exceed deposits in a year.
        let result = evaluate(
            ruleSet: try Fixture.rules(), year: Fixture.year(),
            entries: [Fixture.entry(ReliefCode("SSPN"), -1500)])
        let sspn = try #require(result.assessment(for: ReliefCode("SSPN")))
        #expect(sspn.allowed == .zero)
        #expect(sspn.headroom == Money(ringgit: 8000))   // the cap, not more
    }

    @Test("an automatic relief is granted without any entry")
    func automaticGrant() throws {
        let individual = try #require(
            evaluate(ruleSet: try Fixture.rules(), year: Fixture.year(), entries: [])
                .assessment(for: ReliefCode("SELF_AND_DEPENDENTS")))
        #expect(individual.allowed == Money(ringgit: 9000))
        #expect(individual.headroom == .zero)
    }
}
