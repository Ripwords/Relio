import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

/// Builders for the contribution card, so each test names only the thing it is about.
private enum CardFixture {
    static let year = 2025
    static let cap = Money(ringgit: 4_000)

    static func suggestion(_ confidence: ContributionSuggestion.Confidence,
                           amount: Money = Money(ringgit: 4_000),
                           basis: [ContributionBasis] = []) -> ContributionSuggestion {
        ContributionSuggestion(code: .epfContribution, amount: amount, confidence: confidence,
                               basis: basis, sourceURLs: [], entryID: UUID())
    }

    static func basis(_ name: String,
                      _ months: ClosedRange<WageMonth>?,
                      floor: Money = Money(ringgit: 1_200)) -> ContributionBasis {
        ContributionBasis(sourceID: UUID(), name: name, months: months, floor: floor)
    }

    static func card(_ advice: ContributionAdvice) -> ContributionCard? {
        ReliefCopy.card(for: advice, code: .epfContribution, year: year, cap: cap)
    }

    static let everyAdvice: [ContributionAdvice] = [
        .offer(suggestion(.exactlyTheCap)),
        .offer(suggestion(.atLeast, amount: Money(ringgit: 1_200))),
        .answer([.dateOfBirth, .nationality], worth: Money(ringgit: 320)),
        .crossCheck(logged: Money(ringgit: 1_000), provenFloor: Money(ringgit: 2_000))
    ]
}

/// `App/` sits outside `swift test`'s reach, so these 19 strings had zero coverage while
/// they lived in the view. Both switches in `ReliefCopy` are exhaustive with no `default`,
/// so a rulebook adding a case is a compile error here rather than a silent misrender —
/// these tests exist to catch the remaining way copy can go wrong: a blank or duplicated
/// string that compiles fine but reads wrong on screen. The contribution card joins them
/// here because a card is copy too, made of a headline, a sentence, a caveat and a button
/// label, assembled in one place so the sheet that shows it decides nothing.
@Suite("ReliefCopy") struct ReliefCopyTests {

    @Test("every ProfileQuestion maps to a non-empty string")
    func profileQuestionsAreNonEmpty() {
        for question in ProfileQuestion.allCases {
            #expect(!ReliefCopy.text(for: question).isEmpty)
        }
    }

    @Test("every ProfileQuestion maps to a distinct string")
    func profileQuestionsAreDistinct() {
        let strings = ProfileQuestion.allCases.map { ReliefCopy.text(for: $0) }
        #expect(Set(strings).count == ProfileQuestion.allCases.count)
    }

    @Test("every DocumentKind maps to a non-empty string")
    func documentKindsAreNonEmpty() {
        for kind in DocumentKind.allCases {
            #expect(!ReliefCopy.text(for: kind).isEmpty)
        }
    }

    @Test("every DocumentKind maps to a distinct string")
    func documentKindsAreDistinct() {
        let strings = DocumentKind.allCases.map { ReliefCopy.text(for: $0) }
        #expect(Set(strings).count == DocumentKind.allCases.count)
    }

    @Test("every NationalityClass maps to a non-empty, distinct string")
    func nationalitiesReadDistinctly() {
        let strings = NationalityClass.allCases.map { ReliefCopy.text(for: $0) }
        #expect(strings.allSatisfy { !$0.isEmpty })
        #expect(Set(strings).count == NationalityClass.allCases.count)
    }

    @Test("every ContributionScheme names itself and its statement non-emptily and distinctly")
    func schemesAndStatementsReadDistinctly() {
        let names = ContributionScheme.allCases.map { ReliefCopy.text(for: $0) }
        let statements = ContributionScheme.allCases.map { ReliefCopy.statement(for: $0) }
        #expect(names.allSatisfy { !$0.isEmpty })
        #expect(statements.allSatisfy { !$0.isEmpty })
        #expect(Set(names).count == ContributionScheme.allCases.count)
        #expect(Set(statements).count == ContributionScheme.allCases.count)
    }

    @Test("every ContributionQuestion maps to a non-empty, distinct prompt")
    func questionPromptsReadDistinctly() {
        // One source id across both schemes: the two prompts differ only in the scheme
        // they name, which is exactly the collision a shared string would produce.
        let sourceID = UUID()
        let questions: [ContributionQuestion] = [
            .dateOfBirth,
            .nationality,
            .sourceDeducts(scheme: .employeesProvidentFund, sourceID: sourceID),
            .sourceDeducts(scheme: .socialSecurity, sourceID: sourceID)
        ]
        let prompts = questions.map { ReliefCopy.prompt(for: $0, sourceNamed: "Acme Sdn Bhd") }
        #expect(prompts.allSatisfy { !$0.isEmpty })
        #expect(Set(prompts).count == questions.count)
    }

    @Test("a screen with nothing to say, and a relief that is not a contribution, get no card")
    func noCardWhereThereIsNothingToShow() {
        #expect(CardFixture.card(.none) == nil)
        // Lifestyle has no contribution scheme behind it, so even a live offer renders
        // nothing. The view never has to know which codes are contribution codes.
        #expect(ReliefCopy.card(for: .offer(CardFixture.suggestion(.exactlyTheCap)),
                                code: ReliefCode("LIFESTYLE"),
                                year: 2025,
                                cap: Money(ringgit: 2_500)) == nil)
    }

    @Test("all four advice cases produce filled-in copy, and no two of them read alike")
    func everyAdviceCaseReadsWell() throws {
        var details: [String] = []
        for advice in CardFixture.everyAdvice {
            let card = try #require(CardFixture.card(advice))
            #expect(!card.headline.isEmpty)
            #expect(!card.detail.isEmpty)
            if let caveat = card.caveat { #expect(!caveat.isEmpty) }
            if let action = card.action { #expect(!action.title.isEmpty) }
            details.append(card.detail)
        }
        #expect(Set(details).count == CardFixture.everyAdvice.count)
    }

    /// The whole affordance contract. An exact figure is one tap, because every figure at
    /// or above the floor clamps to the same relief. A floor is not, because Relio has
    /// just told the user this is not the whole of it, so its button opens the editor
    /// prefilled rather than claiming on their behalf.
    @Test("an exact figure offers to add it, a proven floor only offers to start from it")
    func theActionEncodesTheCertainty() throws {
        let exact = try #require(CardFixture.card(.offer(CardFixture.suggestion(.exactlyTheCap))))
        #expect(exact.action?.kind == .addExactly(Money(ringgit: 4_000)))

        let floor = try #require(CardFixture.card(
            .offer(CardFixture.suggestion(.atLeast, amount: Money(ringgit: 1_200)))))
        #expect(floor.action?.kind == .startFrom(Money(ringgit: 1_200)))
    }

    @Test("the cross-check card reassures, carries no button, and quotes both figures")
    func crossCheckNeverAccuses() throws {
        let card = try #require(CardFixture.card(
            .crossCheck(logged: Money(ringgit: 1_000), provenFloor: Money(ringgit: 2_000))))

        #expect(card.action == nil)
        // Two figures are in play, so neither one gets to be the headline.
        #expect(card.headlineAmount == nil)

        let caveat = try #require(card.caveat)
        // Asserted on the reassurance itself rather than on the absence of accusing words:
        // a floor bounds the contribution from below only, so the card has to say out loud
        // that it is never evidence of an over-claim.
        #expect(caveat.contains("only ever prove a floor, never a ceiling"))
        #expect(caveat.contains("never a sign you have claimed too much"))

        #expect(card.detail.contains(Money(ringgit: 2_000).formatted()))
        #expect(card.detail.contains(Money(ringgit: 1_000).formatted()))
    }

    @Test("the prompt says what answering is worth only when there is a figure to say")
    func worthIsQuotedOnlyWhenKnown() throws {
        let unpriced = try #require(CardFixture.card(.answer([.dateOfBirth], worth: nil)))
        #expect(!unpriced.detail.contains("Worth about"))

        let priced = try #require(CardFixture.card(
            .answer([.dateOfBirth], worth: Money(ringgit: 320))))
        #expect(priced.detail.contains("Worth about"))
        #expect(priced.detail.contains(Money(ringgit: 320).formatted()))
    }

    @Test("one proven source is named, several are summarised as the year's records")
    func onlyASingleProvenSourceIsNamedOutright() throws {
        let months = WageMonth(year: 2025, month: 1)...WageMonth(year: 2025, month: 12)

        let single = try #require(CardFixture.card(.offer(CardFixture.suggestion(
            .exactlyTheCap, basis: [CardFixture.basis("Acme Sdn Bhd", months)]))))
        #expect(single.detail.contains("Acme Sdn Bhd"))

        // Two employers, and neither of them speaks for the other.
        let several = try #require(CardFixture.card(.offer(CardFixture.suggestion(
            .exactlyTheCap, basis: [CardFixture.basis("Acme Sdn Bhd", months),
                                    CardFixture.basis("Borneo Trading", months)]))))
        #expect(!several.detail.contains("Acme Sdn Bhd"))
        #expect(several.detail.contains("Your recorded salary for 2025"))
    }

    /// The basis clause is a sentence fragment two different sentences finish, so it is
    /// the one string here whose punctuation and number agreement cannot be read off the
    /// literal it was written as.
    @Test("the basis clause joins its sentence as grammar, not as concatenation")
    func theBasisClauseReadsAsOneSentence() throws {
        let months = WageMonth(year: 2025, month: 1)...WageMonth(year: 2025, month: 12)
        let named = [CardFixture.basis("Acme Sdn Bhd", months)]

        let exact = try #require(CardFixture.card(
            .offer(CardFixture.suggestion(.exactlyTheCap, basis: named))))
        let floor = try #require(CardFixture.card(
            .offer(CardFixture.suggestion(.atLeast, amount: Money(ringgit: 1_200),
                                          basis: named))))
        let generic = try #require(CardFixture.card(
            .offer(CardFixture.suggestion(.exactlyTheCap))))

        // The months are an appositive, so they close with a comma before the verb.
        #expect(exact.detail.contains("December 2025, means you contributed"))
        #expect(floor.detail.contains("December 2025, proves this much."))
        // And the generic clause, which opened no appositive, closes none.
        #expect(generic.detail.contains("Your recorded salary for 2025 means you contributed"))
    }
}
