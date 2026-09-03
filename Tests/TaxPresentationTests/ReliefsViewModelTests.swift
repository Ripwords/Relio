import Testing
import Foundation
@testable import TaxKit
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
        facts.grossIncomeOverride = Money(ringgit: 128_000)
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
        facts.grossIncomeOverride = Money(ringgit: 128_000)
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

    @Test("a code the year does not know clears the screen it had already filled")
    func unknownCode() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)

        // A fresh model pointed at a bad code proves nothing on its own: every field is
        // already empty, so "the guard clears state" and "the guard never runs" look
        // identical. Each case below fills the screen first, then takes the code away.

        // 1. The code is real, but not in the year the user switched to.
        //    HOUSING_LOAN_INTEREST is new in YA2025 and absent from YA2023, while the
        //    2023 evaluation itself succeeds — so this is genuinely "this rulebook has
        //    never heard of that code", not "there is no rulebook".
        var loanInterest = EntryDraft(id: UUID(), year: 2025,
                                      code: ReliefCode("HOUSING_LOAN_INTEREST"),
                                      amount: Money(ringgit: 5_000))
        loanInterest.vendor = "Maybank"
        _ = try await store.save(loanInterest)

        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: ReliefCode("HOUSING_LOAN_INTEREST"))
        await model.refresh()
        #expect(model.assessment != nil)
        #expect(!model.entries.isEmpty)
        #expect(model.sourceURL != nil)
        #expect(model.notes != nil, "HOUSING_LOAN_INTEREST carries a note in YA2025")

        await context.switchYear(to: 2023)
        #expect(context.result != nil, "2023 still evaluates; only the code is unknown there")
        await model.refresh()
        #expect(model.assessment == nil)
        #expect(model.entries.isEmpty)
        #expect(model.subLimits.isEmpty)
        #expect(model.requirements.isEmpty)
        #expect(model.sourceURL == nil)
        #expect(model.notes == nil)

        // 2. The whole year is unavailable. Same guard, and MEDICAL_SERIOUS fills the
        //    two fields HOUSING_LOAN_INTEREST cannot: sub-limits and requirements.
        let medicalContext = PresentationFixture.context(store)
        await medicalContext.load()
        let medical = ReliefDetailViewModel(context: medicalContext, store: store,
                                            code: ReliefCode("MEDICAL_SERIOUS"))
        _ = try await store.save(EntryDraft(id: UUID(), year: 2025,
                                            code: ReliefCode("MEDICAL_SERIOUS"),
                                            amount: Money(ringgit: 6_500)))
        await medicalContext.reload()
        await medical.refresh()
        #expect(!medical.subLimits.isEmpty)
        #expect(!medical.requirements.isEmpty)
        #expect(!medical.entries.isEmpty)

        await medicalContext.switchYear(to: 2026)
        await medical.refresh()
        #expect(medical.assessment == nil)
        #expect(medical.entries.isEmpty)
        #expect(medical.subLimits.isEmpty)
        #expect(medical.requirements.isEmpty)
        #expect(medical.sourceURL == nil)
        #expect(medical.notes == nil)

        // 3. And a code no year has ever shipped still yields an empty screen, not a crash.
        let nonsense = ReliefDetailViewModel(context: medicalContext, store: store,
                                             code: ReliefCode("NOT_A_REAL_CODE"))
        await nonsense.refresh()
        #expect(nonsense.assessment == nil)
        #expect(nonsense.entries.isEmpty)
    }
}

/// The detail screen says "RM 800 still claimable" and, until this, offered no way to
/// claim it — the only route to a new entry was Home's + button, which opens an empty
/// editor and asks the user to find the relief again in a list of two dozen.
@Suite("Relief detail: logging")
@MainActor
struct ReliefDetailLoggingTests {

    static func model(_ store: TaxStore, _ code: ReliefCode) async -> ReliefDetailViewModel {
        let context = PresentationFixture.context(store, year: 2025)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store, code: code)
        await model.refresh()
        return model
    }

    @Test("a claimable relief offers somewhere to log an entry")
    func claimableReliefCanBeLogged() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store, .lifestyle)
        #expect(model.canLogEntries == true)
    }

    /// SELF_AND_DEPENDENTS is granted in full from household facts. The editor already
    /// refuses an entry against it, so the button would walk the user into that refusal.
    @Test("an automatic relief offers nothing to log")
    func automaticReliefCannotBeLogged() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store, .selfAndDependents)
        #expect(model.canLogEntries == false)
    }

    /// A relief blocked on an unanswered question. Logging is not the next step —
    /// answering is, and the screen's "To claim this" section says so.
    @Test("a relief waiting on an answer offers nothing to log")
    func needsInfoReliefCannotBeLogged() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.model(store, .disabledSelf)
        #expect(model.canLogEntries == false)
    }
}

/// A per-dependent relief with no dependants recorded has a cap of zero, and zero headroom
/// with it. Read as "used up", that put CHILD_UNDER_18 under "Fully claimed" and told a
/// user with no children on file that they had claimed all RM 2,000 of it — which is both
/// false and discouraging, since adding a child is exactly what unlocks it.
@Suite("Relief rows: a cap of zero") @MainActor struct ReliefZeroCapTests {

    static func assessment(cap: Money, headroom: Money) -> ReliefAssessment {
        ReliefAssessment(code: .childUnder18, name: "Child under 18",
                         cap: cap, claimed: .zero, allowed: .zero, headroom: headroom,
                         eligibility: .eligible, requirements: [], taxSaved: nil,
                         unverified: false,
                         sourceURL: URL(string: "https://www.hasil.gov.my/")!,
                         notes: nil, children: [])
    }

    @Test("nothing to claim against is not the same as having claimed it all")
    func zeroCapIsNotExhausted() {
        let row = ReliefsListViewModel.row(from: Self.assessment(cap: .zero, headroom: .zero))
        #expect(row.state != .exhausted)
        #expect(row.state == .unavailable)
    }

    /// The genuine case still reads as exhausted: a real cap, all of it used.
    @Test("a relief with a real cap and no room left is still fully claimed")
    func usedUpReliefIsExhausted() {
        let row = ReliefsListViewModel.row(
            from: Self.assessment(cap: Money(ringgit: 2_000), headroom: .zero))
        #expect(row.state == .exhausted)
    }

    @Test("a relief with room left is claimable")
    func reliefWithRoomIsClaimable() {
        let row = ReliefsListViewModel.row(
            from: Self.assessment(cap: Money(ringgit: 2_000), headroom: Money(ringgit: 500)))
        #expect(row.state == .claimable)
    }
}
