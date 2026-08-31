import Testing
import Foundation
import TaxKit
@testable import TaxData
@testable import TaxPresentation

/// `ReliefAssessment` has no public init, so the only honest way to hold one is to run a
/// real evaluation and mutate a copy. A hand-built value could drift from what the engine
/// actually produces for this code, and the whole point of `advise` is that it reads the
/// engine's own numbers.
@MainActor
private enum AdviceFixture {

    static func epfAssessment(cap: Decimal = 4_000,
                              taxSaved: Money? = Money(ringgit: 960),
                              eligibility: Eligibility = .eligible) async throws
        -> ReliefAssessment {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()

        var assessment = try #require(context.result?.assessment(for: .epfContribution))
        assessment.cap = Money(ringgit: cap)
        assessment.taxSaved = taxSaved
        assessment.eligibility = eligibility
        return assessment
    }

    static func estimate(annualFloor: Decimal?,
                         missing: [ContributionQuestion] = []) -> ContributionEstimate {
        ContributionEstimate(scheme: .employeesProvidentFund, year: 2025,
                             annualFloor: annualFloor.map(Money.init(ringgit:)),
                             missing: missing, basis: [], sourceURLs: [])
    }

    static func logged(_ ringgit: Decimal) -> EntryDraft {
        EntryDraft(id: UUID(), year: 2025, code: .epfContribution,
                   amount: Money(ringgit: ringgit))
    }
}

@Suite("ContributionAdvice") @MainActor struct ContributionAdviceTests {

    @Test("a floor that reaches the cap is offered as the cap itself")
    func offersTheCapExactly() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        let estimate = AdviceFixture.estimate(annualFloor: 6_600)

        let advice = ContributionAdvice.advise(estimate: estimate, assessment: assessment,
                                               loggedEntries: [])
        guard case .offer(let suggestion) = advice else {
            Issue.record("expected an offer, got \(advice)")
            return
        }
        #expect(suggestion.confidence == .exactlyTheCap)
        #expect(suggestion.amount == Money(ringgit: 4_000))
        #expect(suggestion.code == ReliefCode.epfContribution)
        #expect(suggestion.entryID == estimate.acceptedEntryID)
    }

    @Test("a floor below the cap is offered as the floor, marked as a lower bound")
    func offersTheFloorAsALowerBound() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        let estimate = AdviceFixture.estimate(annualFloor: 1_200)

        let advice = ContributionAdvice.advise(estimate: estimate, assessment: assessment,
                                               loggedEntries: [])
        guard case .offer(let suggestion) = advice else {
            Issue.record("expected an offer, got \(advice)")
            return
        }
        #expect(suggestion.confidence == .atLeast)
        #expect(suggestion.amount == Money(ringgit: 1_200))
    }

    @Test("a blocked floor asks the questions, priced at the engine's own figure")
    func asksTheBlockingQuestions() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        let estimate = AdviceFixture.estimate(annualFloor: 0,
                                              missing: [.nationality, .dateOfBirth])

        let advice = ContributionAdvice.advise(estimate: estimate, assessment: assessment,
                                               loggedEntries: [])
        // `worth` is the assessment's own `taxSaved`, not a second tax calculation.
        #expect(advice == .answer([.nationality, .dateOfBirth], worth: Money(ringgit: 960)))
    }

    @Test("no wage records means nothing to say")
    func silentWithoutWages() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: nil),
                                          assessment: assessment,
                                          loggedEntries: []) == .none)
    }

    @Test("an ineligible relief is never advised on")
    func ineligibleIsSilent() async throws {
        let assessment = try await AdviceFixture.epfAssessment(
            eligibility: .ineligible(reasons: ["Not available this year"]))
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 6_600),
                                          assessment: assessment,
                                          loggedEntries: []) == .none)
    }

    @Test("an unanswered eligibility question does not silence the offer")
    func needsInfoFallsThrough() async throws {
        // `.needsInfo` is the engine's "we have not asked yet", not a refusal. Treating it
        // as ineligibility would cost the user the relief for a question nobody put to them.
        let assessment = try await AdviceFixture.epfAssessment(
            eligibility: .needsInfo(questions: [.employmentType]))
        let advice = ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 6_600),
                                               assessment: assessment, loggedEntries: [])
        guard case .offer(let suggestion) = advice else {
            Issue.record("expected an offer, got \(advice)")
            return
        }
        #expect(suggestion.confidence == .exactlyTheCap)
    }

    @Test("a logged figure below the proven floor is cross-checked")
    func crossChecksAnUnderClaim() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        let advice = ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 3_800),
                                               assessment: assessment,
                                               loggedEntries: [AdviceFixture.logged(2_000),
                                                               AdviceFixture.logged(1_200)])
        #expect(advice == .crossCheck(logged: Money(ringgit: 3_200),
                                      provenFloor: Money(ringgit: 3_800)))
    }

    @Test("a logged figure above the proven floor is left alone")
    func neverCrossChecksAnOverClaim() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        // A floor proves someone claimed too little and can never prove they claimed too
        // much, so this direction has to stay silent — the user's own figure may well be
        // the true one, and Relio has no standing to call it wrong.
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 3_800),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(3_900)]) == .none)
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 3_800),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(3_800)]) == .none)
    }

    @Test("a floor above the cap does not nag a claim already at the cap")
    func floorIsClampedToTheCap() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        // The statutory floor is RM6,600 but the relief stops at RM4,000, and the user has
        // logged RM4,000. There is nothing left to fix, so there is nothing to say.
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 6_600),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(4_000)]) == .none)
        // Below the cap the clamped floor still fires, and it fires at the cap rather than
        // at the uncapped figure the user could not claim anyway.
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 6_600),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(1_000)])
                == .crossCheck(logged: Money(ringgit: 1_000),
                               provenFloor: Money(ringgit: 4_000)))
    }

    @Test("a deliberate zero is an under-claim like any other")
    func zeroIsStillAnUnderClaim() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        // Someone who typed RM0.00 against records proving RM3,800 has under-claimed by
        // RM3,800. Nothing about the figure being zero makes it a case worth skipping.
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: 3_800),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(0)])
                == .crossCheck(logged: .zero, provenFloor: Money(ringgit: 3_800)))
    }

    @Test("a logged entry against no wage records at all says nothing")
    func loggedWithoutWagesIsSilent() async throws {
        let assessment = try await AdviceFixture.epfAssessment()
        #expect(ContributionAdvice.advise(estimate: AdviceFixture.estimate(annualFloor: nil),
                                          assessment: assessment,
                                          loggedEntries: [AdviceFixture.logged(500)]) == .none)
    }
}
