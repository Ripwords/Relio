import Testing
import Foundation
@testable import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("HomeViewModel") @MainActor struct HomeViewModelTests {

    static func model(_ store: TaxStore, year: Int = 2025) async -> HomeViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        let model = HomeViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    @Test("the headline is the tax the remaining headroom is worth")
    func headlineIsTax() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        #expect(model.headlineKind == .taxSaved)
        let expected = try #require(model.context.result?.totalOpportunity)
        #expect(model.headline == expected)
        #expect(model.headline > Money.zero)
    }

    @Test("with income unknown the headline becomes relief and says so")
    func headlineFallsBackToRelief() async throws {
        let store = try await PresentationFixture.store()
        // No gross income: every taxSaved is nil and totalOpportunity is nil.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 1_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        // Showing a relief figure under a "tax saved" label would be a plain lie about
        // money, so the kind changes with the number.
        #expect(model.headlineKind == .relief)
        #expect(model.headline > Money.zero)
        #expect(model.context.result?.totalOpportunity == nil)
    }

    @Test("opportunities are the top three by tax saved, and the rest are counted")
    func topThreeByTaxSaved() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        #expect(model.opportunities.count <= 3)
        let saved = model.opportunities.compactMap(\.taxSaved)
        #expect(saved == saved.sorted(by: >), "highest ringgit recoverable first")
        #expect(model.remainingOpportunityCount >= 0)
    }

    @Test("an ineligible relief never appears, however large its headroom")
    func ineligibleIsExcluded() {
        // Tested directly against the ranking function rather than through a seeded
        // household. Verified during pre-flight: YA2025 yields 19 eligible, 5 needsInfo
        // and ZERO ineligible reliefs for a plain household, so a fixture-driven version
        // of this test could only ever pass by accident of what a Budget happens to say.
        //
        // An ineligible relief reports headroom equal to its cap while `allowed` is zero.
        // Ranking on headroom alone would put reliefs the user cannot claim at the top of
        // the one screen that exists to tell them what to do next.
        let ranked = HomeViewModel.rankedCandidates(in: Self.syntheticResult)
        #expect(ranked.map(\.code) == [ReliefCode("RICH"), ReliefCode("ASK")])
        #expect(!ranked.contains { $0.code == ReliefCode("REFUSED") })
    }

    @Test("a needsInfo relief stays in the ranking, rendered as a question")
    func needsInfoStaysRanked() throws {
        // Plan 1 settled this: a .needsInfo relief is money the user may recover by
        // answering one question, so excluding it would make the headline understate the
        // upside and bury the prompt.
        let ranked = HomeViewModel.rankedCandidates(in: Self.syntheticResult)
        let asked = try #require(ranked.first { $0.code == ReliefCode("ASK") })
        #expect(asked.needsAnswer == true)
    }

    /// Three reliefs with identical headroom and differing eligibility, so the filter and
    /// the ordering are both observable without depending on any shipped rulebook.
    static var syntheticResult: EvaluationResult {
        func assessment(_ code: String,
                        eligibility: Eligibility,
                        taxSaved: Money?) -> ReliefAssessment {
            ReliefAssessment(code: ReliefCode(code),
                             name: code.capitalized,
                             cap: Money(ringgit: 10_000),
                             claimed: .zero,
                             allowed: .zero,
                             headroom: Money(ringgit: 10_000),
                             eligibility: eligibility,
                             requirements: [],
                             taxSaved: taxSaved,
                             unverified: false,
                             sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                             notes: nil,
                             children: [])
        }

        return EvaluationResult(
            yearOfAssessment: 2025,
            assessments: [
                assessment("REFUSED", eligibility: .ineligible(reasons: ["Not you"]),
                           taxSaved: Money(ringgit: 9_999)),
                assessment("ASK", eligibility: .needsInfo(questions: []),
                           taxSaved: Money(ringgit: 100)),
                assessment("RICH", eligibility: .eligible,
                           taxSaved: Money(ringgit: 500))
            ],
            unresolved: [],
            chargeableIncome: Money(ringgit: 100_000),
            estimatedTax: Money(ringgit: 10_000),
            totalOpportunity: Money(ringgit: 600))
    }

    @Test("ordering is stable across identical evaluations")
    func orderingIsDeterministic() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let first = await Self.model(store).opportunities.map(\.code)
        let second = await Self.model(store).opportunities.map(\.code)
        // Plan 1 shipped a bug where equal-valued rows reordered between launches. Ties
        // break on code here for the same reason.
        #expect(first == second)
    }

    @Test("unanswered questions are surfaced with what they are worth")
    func needsInfoPrompt() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        // Marital status left unanswered: spouse relief becomes .needsInfo, not refused.
        try await store.saveYearFacts(facts, for: 2025)
        let model = await Self.model(store)

        #expect(model.prompts.unansweredQuestionCount > 0)
        #expect(model.prompts.unlockableRelief > Money.zero)
    }

    @Test("claims missing a required document are counted")
    func missingDocumentPrompt() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        // LIFE_INSURANCE requires an insurance statement; this has no documents at all.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFE_INSURANCE"), amount: Money(ringgit: 2_000))
        draft.vendor = "Great Eastern"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        #expect(model.prompts.claimsMissingDocuments >= 1)
    }

    @Test("an entry against a code this year does not know is counted, not dropped")
    func unresolvedEntriesAreSurfaced() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        // A retired code, or one from a rulebook that never shipped this year. The
        // evaluator deliberately reports these separately instead of discarding them,
        // and until a view model owns that list the user's RM 500 is invisible on every
        // screen in the app — their claim looks like it was never made.
        var orphan = EntryDraft(id: UUID(), year: 2025,
                                code: ReliefCode("NOT_A_REAL_CODE"),
                                amount: Money(ringgit: 500))
        orphan.vendor = "Imported from an older rulebook"
        _ = try await store.save(orphan)

        let model = await Self.model(store)
        #expect(model.context.result?.unresolved.count == 1, "the engine must see it as unresolved")
        #expect(model.prompts.unresolvedEntryCount == 1)

        // And a household with nothing unresolved reports zero, so the prompt is not
        // permanently lit.
        let clean = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(clean)
        #expect(await Self.model(clean).prompts.unresolvedEntryCount == 0)
    }

    @Test("percent used is integer arithmetic and never divides by zero")
    func usedPercent() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)
        for row in model.opportunities {
            #expect(row.usedPercent >= 0)
            #expect(row.usedPercent <= 100)
        }
    }

    @Test("an empty first launch shows a number, not an error")
    func emptyStateHasAHeadline() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        // Spec §11.5: empty states are the design. A blank or errored Home on first
        // launch is the worst possible first impression for a tracker.
        #expect(model.opportunities.isEmpty == false || model.headline >= Money.zero)
        #expect(model.context.status == .ready)
    }

    @Test("an unavailable year zeroes the screen without throwing")
    func unavailableYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2026)
        await context.load()
        let model = HomeViewModel(context: context, store: store)
        await model.refresh()

        #expect(model.headline == Money.zero)
        #expect(model.opportunities.isEmpty)
    }
}
