import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("ReliefsListViewModel") @MainActor struct ReliefsListViewModelTests {

    static func model(_ store: TaxStore) async -> ReliefsListViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefsListViewModel(context: context)
        model.refresh()
        return model
    }

    @Test("sections appear in action order, not alphabetical order")
    func sectionOrder() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        let titles = model.sections.map(\.title)
        let expected = ["Needs an answer", "Still claimable", "Fully claimed", "Not applicable to you"]
        // Alphabetical order would bury the two groups the user can act on.
        #expect(titles == expected.filter(titles.contains))
        #expect(titles == titles.sorted { expected.firstIndex(of: $0)! < expected.firstIndex(of: $1)! })
    }

    @Test("every top-level relief in the year appears exactly once")
    func everyReliefAppears() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        let listed = model.sections.flatMap(\.rows).map(\.code)
        let expected = try #require(model.context.result).assessments.map(\.code)
        #expect(Set(listed) == Set(expected))
        #expect(listed.count == expected.count, "no relief listed twice")
    }

    @Test("a relief with no room left is fully claimed, not still claimable")
    func exhaustedReliefIsSeparated() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)
        // Well past the RM 2,500 lifestyle cap.
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 9_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)
        let model = await Self.model(store)

        let row = try #require(model.sections.flatMap(\.rows).first { $0.code == ReliefCode("LIFESTYLE") })
        #expect(row.state == .exhausted)
        #expect(row.usedPercent == 100)
        #expect(row.headroom == Money.zero)
    }

    @Test("search filters by name and by code")
    func search() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store)

        model.searchText = "lifestyle"
        model.refresh()
        let byName = model.sections.flatMap(\.rows).map(\.code)
        #expect(byName.contains(ReliefCode("LIFESTYLE")))
        #expect(byName.allSatisfy {
            $0.rawValue.lowercased().contains("lifestyle")
                || (model.context.result?.assessment(for: $0)?.name.lowercased().contains("lifestyle") ?? false)
        })

        model.searchText = ""
        model.refresh()
        #expect(model.sections.flatMap(\.rows).count > byName.count)
    }

    @Test("an unavailable year yields no sections and does not throw")
    func unavailableYear() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store, year: 2026)
        await context.load()
        let model = ReliefsListViewModel(context: context)
        model.refresh()
        #expect(model.sections.isEmpty)
    }
}

@Suite("ReliefDetailViewModel") @MainActor struct ReliefDetailViewModelTests {

    @Test("detail shows claimed and allowed separately when a cap binds")
    func claimedAndAllowedDiffer() async throws {
        let store = try await PresentationFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("LIFESTYLE"), amount: Money(ringgit: 9_000))
        draft.vendor = "Popular"
        _ = try await store.save(draft)

        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store, code: ReliefCode("LIFESTYLE"))
        await model.refresh()

        let assessment = try #require(model.assessment)
        // Showing only `allowed` hides that the claim was trimmed; showing only
        // `claimed` overstates what LHDN would permit. The screen shows both.
        #expect(assessment.claimed == Money(ringgit: 9_000))
        #expect(assessment.allowed < assessment.claimed)
    }

    @Test("detail lists only this relief's entries")
    func entriesAreScoped() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store, code: ReliefCode("LIFESTYLE"))
        await model.refresh()

        #expect(!model.entries.isEmpty)
        #expect(model.entries.allSatisfy { $0.code == ReliefCode("LIFESTYLE") })
    }

    @Test("detail surfaces the LHDN source and any sub-limits")
    func sourceAndSubLimits() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: ReliefCode("MEDICAL_SERIOUS"))
        await model.refresh()

        // Spec success criterion 2: every figure traces to a rulebook value carrying an
        // LHDN source URL, and the detail screen is where the user sees it.
        #expect(model.sourceURL?.host()?.contains("hasil.gov.my") == true)
        #expect(!model.subLimits.isEmpty, "MEDICAL_SERIOUS has sub-limits in YA2025")
    }

    @Test("an unknown code yields an empty screen rather than a crash")
    func unknownCode() async throws {
        let store = try await PresentationFixture.store()
        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: ReliefCode("NOT_A_REAL_CODE"))
        await model.refresh()
        #expect(model.assessment == nil)
        #expect(model.entries.isEmpty)
    }
}
