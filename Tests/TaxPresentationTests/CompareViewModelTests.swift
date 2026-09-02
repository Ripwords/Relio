import Testing
import Foundation
@testable import TaxKit
import TaxData
@testable import TaxPresentation

/// TaxKit has shipped `counterfactual(entries:year:under:versus:)` since the first plan,
/// tested, with no screen anywhere calling it. It answers the question the spec calls the
/// one worth building — not "the cap went up" but "the cap going up is worth RM 1,680 to
/// you" — by replaying the user's own entries under another year's rulebook.
@Suite("Compare years")
@MainActor
struct CompareViewModelTests {

    static func model(_ store: TaxStore, baseline: Int = 2025) async -> CompareViewModel {
        let model = CompareViewModel(store: store,
                                     loader: BundledRuleSetLoader(),
                                     baselineYear: baseline)
        await model.refresh()
        return model
    }

    /// The nearest earlier shipped year is the useful default: "what changed since last
    /// year" is the question someone opens this screen with.
    @Test("comparison defaults to the year before the one being viewed")
    func defaultsToPreviousYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store, baseline: 2025)
        #expect(model.comparisonYear == 2024)
    }

    /// The year being viewed cannot be compared with itself — an all-zero diff is not a
    /// screen, and offering it in the picker invites the tap.
    @Test("the baseline year is not offered as its own comparison")
    func baselineIsNotAComparisonOption() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store, baseline: 2025)
        #expect(!model.comparisonYears.contains(2025))
        #expect(model.comparisonYears.allSatisfy { BundledRuleSetLoader().availableYears.contains($0) })
    }

    /// The headline has to name a direction, and getting the sign backwards would tell
    /// someone a rule change cost them money when it made them money.
    ///
    /// `totalReliefDifference` is `baseline - comparison`, so a positive number means the
    /// year being viewed allows more relief than the year compared against.
    @Test("a year that allows more relief reads as better off")
    func directionFollowsTheSign() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store, baseline: 2025)

        let result = try #require(model.result)
        // YA2025 raised the disabled individual, disabled spouse and education/medical
        // insurance reliefs, so replaying the same entries under YA2024 must not come out
        // ahead. The assertion is on the direction, not on a figure a Budget could move.
        #expect(result.totalReliefDifference.sen >= 0)
        #expect(model.direction == (result.totalReliefDifference.sen > 0 ? .betterOff : .noDifference))
    }

    /// Switching the comparison re-runs the counterfactual. A picker that changed a label
    /// and left last year's figures underneath would be worse than no picker.
    @Test("changing the comparison year re-evaluates")
    func switchingComparisonReevaluates() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store, baseline: 2025)
        let before = try #require(model.result)

        await model.compare(with: 2023)
        let after = try #require(model.result)
        #expect(after.comparisonYA == 2023)
        #expect(before.comparisonYA == 2024)
    }

    /// A user with nothing logged gets an honest empty state rather than a screen of
    /// zeroes: with no entries there is nothing to replay, so no rule change is worth
    /// anything to them yet.
    @Test("no entries means no differences, not a wall of zeroes")
    func emptyProfileHasNoLines() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store, baseline: 2025)
        let result = try #require(model.result)
        #expect(result.lines.allSatisfy { $0.difference != .zero })
    }
}
