import Testing
import Foundation
@testable import TaxKit
import TaxData
@testable import TaxPresentation

/// Home's "8 claims need documents" prompt led nowhere. This is the model behind the
/// screen it now opens.
///
/// The screen deliberately does not offer to attach anything — capture is not built. What
/// it can do honestly is name the claims and the document each one is missing, which is
/// what someone needs before they go looking through a drawer. A list that promised
/// attachment and could not deliver would be the same dead end one level deeper.
@Suite("Documents outstanding")
@MainActor
struct DocumentsViewModelTests {

    static func model(_ store: TaxStore, year: Int = 2025) async -> DocumentsViewModel {
        let context = PresentationFixture.context(store, year: year)
        await context.load()
        let model = DocumentsViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    @Test("a claim carrying every document it needs is not listed")
    func satisfiedClaimsAreNotListed() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)
        // Whatever the rulebook asks for, nothing satisfied may appear.
        #expect(model.outstanding.allSatisfy { !$0.kinds.isEmpty })
    }

    /// One entry missing two document kinds is one row, not two. The engine reports
    /// requirements per kind, each carrying the entries missing it, so the natural shape
    /// of that data is per kind — and rendering it that way would show the same receipt
    /// twice and count its money twice in the total.
    @Test("an entry missing two kinds is one row carrying both")
    func oneRowPerEntry() {
        let rows = DocumentsViewModel.rows(in: Self.twoKindsMissing, entries: Self.entries)
        #expect(rows.count == 1)
        #expect(rows.first?.kinds == [.officialReceipt, .taxInvoice])
    }

    /// The figure the screen leads with. An entry missing two documents is one claim at
    /// risk, not two — summing per requirement would report RM 3,400 for a single
    /// RM 1,700 receipt.
    @Test("the total at risk counts each claim once")
    func totalCountsEachClaimOnce() {
        let rows = DocumentsViewModel.rows(in: Self.twoKindsMissing, entries: Self.entries)
        #expect(DocumentsViewModel.totalAtRisk(rows) == Money(ringgit: 1_700))
    }

    /// An entry the evaluator names but the store no longer holds — deleted mid-refresh,
    /// or arrived from another device — must not put a blank row on screen.
    @Test("an entry the store does not have is skipped, not rendered empty")
    func unknownEntryIsSkipped() {
        let rows = DocumentsViewModel.rows(in: Self.twoKindsMissing, entries: [])
        #expect(rows.isEmpty)
    }

    /// The prompt and the screen it opens must report the same number. They were counted
    /// two different ways — Home from the store's per-entry `needsDocument` flag, the tab
    /// from the evaluator's requirement checks — and disagreed by two on the seeded
    /// household: "8 claims need documents" opening a list of six.
    @Test("Home's count is the number of rows the Docs tab will show")
    func homeAgreesWithTheScreenItOpens() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let home = HomeViewModel(context: context, store: store)
        await home.refresh()
        let documents = DocumentsViewModel(context: context, store: store)
        await documents.refresh()

        #expect(home.prompts.claimsMissingDocuments == documents.outstanding.count)
    }

    /// Two claims for the same amount is ordinary — two receipts, one price. The order
    /// has to be the same every launch, or the list appears to shuffle itself.
    @Test("equal amounts order deterministically, biggest first overall")
    func tiesBreakOnIdentity() {
        let low = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
        let high = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
        let big = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!

        let entries = [
            EntryDraft(id: high, year: 2025, code: .lifestyle,
                       amount: Money(ringgit: 100), vendor: "Second"),
            EntryDraft(id: low, year: 2025, code: .lifestyle,
                       amount: Money(ringgit: 100), vendor: "First"),
            EntryDraft(id: big, year: 2025, code: .lifestyle,
                       amount: Money(ringgit: 900), vendor: "Biggest"),
        ]
        let result = Self.missingReceipts(for: [low, high, big])
        let rows = DocumentsViewModel.rows(in: result, entries: entries)

        #expect(rows.map(\.vendor) == ["Biggest", "First", "Second"])
        // Same input in a different order must land the same way.
        #expect(DocumentsViewModel.rows(in: result, entries: entries.reversed())
                .map(\.vendor) == ["Biggest", "First", "Second"])
    }

    static func missingReceipts(for ids: [UUID]) -> EvaluationResult {
        EvaluationResult(
            yearOfAssessment: 2025,
            assessments: [
                ReliefAssessment(code: .lifestyle, name: "Lifestyle",
                                 cap: Money(ringgit: 2_500), claimed: .zero, allowed: .zero,
                                 headroom: Money(ringgit: 2_500), eligibility: .eligible,
                                 requirements: [RequirementCheck(kind: .officialReceipt,
                                                                 status: .missing(entryIDs: ids))],
                                 taxSaved: nil, unverified: false,
                                 sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                                 notes: nil, children: [])
            ],
            unresolved: [], chargeableIncome: nil, estimatedTax: nil, totalOpportunity: nil)
    }

    static let entryID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!

    static var entries: [EntryDraft] {
        [EntryDraft(id: entryID,
                    year: 2025,
                    code: .lifestyle,
                    amount: Money(ringgit: 1_700),
                    vendor: "Kinokuniya")]
    }

    /// One relief, one entry, two document kinds outstanding against it.
    static var twoKindsMissing: EvaluationResult {
        EvaluationResult(
            yearOfAssessment: 2025,
            assessments: [
                ReliefAssessment(code: .lifestyle,
                                 name: "Lifestyle — books, computer",
                                 cap: Money(ringgit: 2_500),
                                 claimed: Money(ringgit: 1_700),
                                 allowed: Money(ringgit: 1_700),
                                 headroom: Money(ringgit: 800),
                                 eligibility: .eligible,
                                 requirements: [
                                    RequirementCheck(kind: .officialReceipt,
                                                     status: .missing(entryIDs: [entryID])),
                                    RequirementCheck(kind: .taxInvoice,
                                                     status: .missing(entryIDs: [entryID])),
                                    RequirementCheck(kind: .eInvoice, status: .satisfied),
                                 ],
                                 taxSaved: Money(ringgit: 152),
                                 unverified: false,
                                 sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                                 notes: nil,
                                 children: [])
            ],
            unresolved: [],
            chargeableIncome: Money(ringgit: 100_000),
            estimatedTax: Money(ringgit: 10_000),
            totalOpportunity: Money(ringgit: 152))
    }
}
