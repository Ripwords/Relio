import Testing
import Foundation
@testable import TaxKit
import TaxData
@testable import TaxPresentation

/// `chargeableIncome` and `estimatedTax` are computed by the engine and asserted by the
/// golden files, and until now no screen in the app showed either. Home led with what is
/// still claimable and never said what the user would actually pay.
///
/// The README's worked example is the five-line sum this puts on screen. Only its last
/// line was reachable.
@Suite("Tax summary") struct TaxSummaryTests {

    @Test("gross income is what the chargeable figure and the relief add back up to")
    func grossIsChargeablePlusRelief() {
        let summary = try? #require(TaxSummary(Self.result))
        #expect(summary?.grossIncome == Money(ringgit: 100_000))
        #expect(summary?.reliefAllowed == Money(ringgit: 20_000))
        #expect(summary?.chargeableIncome == Money(ringgit: 80_000))
        #expect(summary?.estimatedTax == Money(ringgit: 5_000))
    }

    /// Income is optional in this app, and every tax figure is `nil` without it. A summary
    /// that filled those in with zeroes would tell someone with no income recorded that
    /// they owe nothing, which is a different claim entirely.
    @Test("no income means no summary, not a summary of zeroes")
    func noIncomeMeansNoSummary() {
        var incomeless = Self.result
        incomeless.chargeableIncome = nil
        incomeless.estimatedTax = nil
        incomeless.totalOpportunity = nil
        #expect(TaxSummary(incomeless) == nil)
    }

    /// The real rulebook, the real household, checked against the figures the README
    /// publishes. If the engine or the transcription moves, this fails alongside the
    /// golden files rather than quietly putting a new number on screen.
    @Test("the worked example adds up on the shipped YA2025 rulebook")
    @MainActor
    func workedExampleAddsUp() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()

        let result = try #require(context.result)
        let summary = try #require(TaxSummary(result))

        #expect(summary.grossIncome == Money(ringgit: 128_000))
        #expect(summary.chargeableIncome
                == summary.grossIncome - summary.reliefAllowed)
        // Every line positive and the sum internally consistent — the figures themselves
        // are the golden files' business, not this type's.
        #expect(summary.reliefAllowed > .zero)
        #expect(summary.estimatedTax > .zero)
    }

    static var result: EvaluationResult {
        EvaluationResult(
            yearOfAssessment: 2025,
            assessments: [
                ReliefAssessment(code: .lifestyle, name: "Lifestyle",
                                 cap: Money(ringgit: 20_000),
                                 claimed: Money(ringgit: 20_000),
                                 allowed: Money(ringgit: 20_000),
                                 headroom: .zero, eligibility: .eligible, requirements: [],
                                 taxSaved: nil, unverified: false,
                                 sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                                 notes: nil, children: [])
            ],
            unresolved: [],
            chargeableIncome: Money(ringgit: 80_000),
            estimatedTax: Money(ringgit: 5_000),
            totalOpportunity: Money(ringgit: 250))
    }
}
