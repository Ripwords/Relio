import Testing
import Foundation
@testable import TaxKit

@Suite("Eligibility") struct EligibilityTests {

    func facts(_ mutate: (inout Facts) -> Void = { _ in }) -> Facts {
        var f = Facts(yearOfAssessment: 2025)
        mutate(&f)
        return f
    }

    @Test("a known matching fact is satisfied")
    func knownMatch() {
        let p = EligibilityPredicate.maritalStatus(in: [.married])
        #expect(p.evaluate(facts { $0.maritalStatus = .married }) == .satisfied)
    }

    @Test("a known non-matching fact fails with a reason")
    func knownMismatch() {
        let p = EligibilityPredicate.maritalStatus(in: [.married])
        let outcome = p.evaluate(facts { $0.maritalStatus = .single })
        guard case .failed(let reason) = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
        #expect(reason.contains("married"))
    }

    @Test("a missing fact is unknown and names the question to ask")
    func missingFactIsUnknown() {
        let p = EligibilityPredicate.spouseHasIncome(false)
        #expect(p.evaluate(facts()) == .unknown(missing: [.spouseHasIncome]))
    }

    @Test("all: one failure fails the whole predicate even with unknowns present")
    func allShortCircuitsOnFailure() {
        let p = EligibilityPredicate.all([
            .maritalStatus(in: [.married]),
            .spouseHasIncome(false)
        ])
        let outcome = p.evaluate(facts { $0.maritalStatus = .single })
        guard case .failed = outcome else {
            Issue.record("expected .failed, got \(outcome)"); return
        }
    }

    @Test("all: unknowns accumulate when nothing has failed")
    func allAccumulatesUnknowns() {
        let p = EligibilityPredicate.all([
            .spouseHasIncome(false),
            .employmentType(in: [.publicServantPensionable])
        ])
        #expect(p.evaluate(facts()) == .unknown(missing: [.spouseHasIncome, .employmentType]))
    }

    @Test("any: one satisfied child satisfies the whole predicate")
    func anySatisfies() {
        let p = EligibilityPredicate.any([
            .maritalStatus(in: [.married]),
            .spouseHasIncome(false)
        ])
        #expect(p.evaluate(facts { $0.maritalStatus = .married }) == .satisfied)
    }

    @Test("any: all children failing fails the whole predicate")
    func anyFails() {
        let p = EligibilityPredicate.any([.maritalStatus(in: [.married])])
        guard case .failed = p.evaluate(facts { $0.maritalStatus = .single }) else {
            Issue.record("expected .failed"); return
        }
    }

    @Test("not inverts satisfied and failed but preserves unknown")
    func notInverts() {
        let known = facts { $0.maritalStatus = .married }
        guard case .failed = EligibilityPredicate.not(.maritalStatus(in: [.married])).evaluate(known) else {
            Issue.record("expected .failed"); return
        }
        #expect(EligibilityPredicate.not(.spouseHasIncome(false)).evaluate(facts())
                == .unknown(missing: [.spouseHasIncome]))
    }

    @Test("dependent age bounds are inclusive")
    func dependentAgeBounds() {
        let p = EligibilityPredicate.dependentAge(min: nil, max: 18)
        #expect(p.evaluate(facts { $0.dependent = DependentFacts(ageAtYearEnd: 18) }) == .satisfied)
        guard case .failed = p.evaluate(facts { $0.dependent = DependentFacts(ageAtYearEnd: 19) }) else {
            Issue.record("expected .failed at 19"); return
        }
        #expect(p.evaluate(facts()) == .unknown(missing: [.dependentDetails]))
    }

    @Test("yaRange is evaluated against the ruleset year, which is always known")
    func yaRange() {
        let p = EligibilityPredicate.yaRange(from: 2025, to: 2027)
        #expect(p.evaluate(facts()) == .satisfied)
        var earlier = facts(); earlier.yearOfAssessment = 2024
        guard case .failed = p.evaluate(earlier) else {
            Issue.record("expected .failed for 2024"); return
        }
    }

    @Test("claim frequency: never claimed is satisfied, too recent fails, unknown asks")
    func claimFrequency() {
        let p = EligibilityPredicate.claimFrequency(everyNYears: 2)
        #expect(p.evaluate(facts { $0.claimHistory = .neverClaimed }) == .satisfied)
        #expect(p.evaluate(facts { $0.claimHistory = .lastClaimed(yearsAgo: 2) }) == .satisfied)
        guard case .failed = p.evaluate(facts { $0.claimHistory = .lastClaimed(yearsAgo: 1) }) else {
            Issue.record("expected .failed after 1 year"); return
        }
        #expect(p.evaluate(facts()) == .unknown(missing: [.lastClaimYear]))
    }

    @Test("round-trips through JSON")
    func codableRoundTrip() throws {
        let original = EligibilityPredicate.all([
            .maritalStatus(in: [.married, .divorced]),
            .not(.spouseHasIncome(true)),
            .any([.dependentAge(min: 18, max: nil), .dependentIsDisabled(true)]),
            .yaRange(from: 2025, to: nil),
            .claimant(in: [.individual, .spouse, .child])
        ])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(EligibilityPredicate.self, from: data) == original)
    }

    @Test("decodes the wire format used in the rulebook JSON")
    func decodesWireFormat() throws {
        let json = """
        { "op": "all", "of": [
            { "op": "claimant", "in": ["self", "spouse", "child"] },
            { "op": "dependentAge", "max": 18 }
        ] }
        """
        let decoded = try JSONDecoder().decode(EligibilityPredicate.self, from: Data(json.utf8))
        #expect(decoded == .all([
            .claimant(in: [.individual, .spouse, .child]),
            .dependentAge(min: nil, max: 18)
        ]))
    }
}
