import Testing
import Foundation
import TaxKit
@testable import TaxData
@testable import TaxPresentation

@MainActor
private enum AcceptanceFixture {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    static let acceptedID = WellKnownID.acceptedContribution(scheme: .employeesProvidentFund,
                                                             year: 2025)

    /// A salaried job that deducts EPF, high enough that 11% of it clears the RM4,000 cap.
    static func seedSalariedJob(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncomeOverride = Money(ringgit: 128_000)
        try await store.saveYearFacts(facts, for: 2025)

        var job = IncomeSourceDraft(name: "Main job")
        // `nil` proves nothing by design, so the flag has to be a real answer.
        job.deductsEPF = true
        let sourceID = try await store.save(job)

        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 5_000)
        rate.effectiveFrom = date(2024, 1, 1)
        _ = try await store.save(rate)
    }

    /// A YA2025 EPF screen whose advice is a one-tap offer.
    static func offering() async throws -> (store: TaxStore,
                                            context: YearContext,
                                            model: ReliefDetailViewModel) {
        let store = try await PresentationFixture.store()
        try await seedSalariedJob(store)
        try await store.saveContributorProfile(
            ContributorProfile(dateOfBirth: date(1990, 3, 12), nationality: .malaysianCitizen))

        let context = PresentationFixture.context(store)
        await context.load()
        let model = ReliefDetailViewModel(context: context, store: store,
                                          code: .epfContribution)
        await model.refresh()
        return (store, context, model)
    }

    static func epfEntries(in store: TaxStore) async throws -> [EntryDraft] {
        try await store.entryDrafts(forYear: 2025).filter { $0.code == .epfContribution }
    }
}

@Suite("Contribution acceptance") @MainActor struct ContributionAcceptanceTests {

    @Test("a salaried year with a known contributor is offered the cap")
    func offersTheCap() async throws {
        let (_, _, model) = try await AcceptanceFixture.offering()
        guard case .offer(let suggestion) = model.advice else {
            Issue.record("expected an offer, got \(model.advice)")
            return
        }
        #expect(suggestion.confidence == .exactlyTheCap)
        #expect(suggestion.amount == Money(ringgit: 4_000))
        #expect(suggestion.entryID == AcceptanceFixture.acceptedID)
    }

    @Test("two screens accepting the same offer write one entry, not two")
    func acceptanceIsIdempotent() async throws {
        let (store, context, model) = try await AcceptanceFixture.offering()
        // A second screen that refreshed before the first tap landed, which is what a tap
        // on another device looks like from here: its `advice` still offers, so it writes.
        let racing = ReliefDetailViewModel(context: context, store: store,
                                           code: .epfContribution)
        await racing.refresh()

        #expect(await model.acceptSuggestion())
        #expect(await racing.acceptSuggestion())

        let entries = try await AcceptanceFixture.epfEntries(in: store)
        #expect(entries.count == 1)
        #expect(entries.first?.id == AcceptanceFixture.acceptedID)

        // The same screen's second tap cannot reach the write at all: its own refresh has
        // already taken the offer away.
        #expect(await model.acceptSuggestion() == false)
        #expect(try await AcceptanceFixture.epfEntries(in: store).count == 1)
    }

    @Test("accepting after a delete revives the row rather than adding a second")
    func acceptanceRevivesADeletedRow() async throws {
        let (store, context, model) = try await AcceptanceFixture.offering()
        #expect(await model.acceptSuggestion())

        try await store.softDeleteEntry(id: AcceptanceFixture.acceptedID)
        await context.reload()
        await model.refresh()
        #expect(model.entries.isEmpty)

        // Revival is the ordinary write path's own behaviour — `save(_ draft: EntryDraft)`
        // fetches by id regardless of `deletedAt` — so acceptance needs no revival code of
        // its own, and inserting a second row would double the relief.
        #expect(await model.acceptSuggestion())
        let entries = try await AcceptanceFixture.epfEntries(in: store)
        #expect(entries.count == 1)
        #expect(entries.first?.id == AcceptanceFixture.acceptedID)
    }

    @Test("a screen with no offer writes nothing")
    func refusesWithoutAnOffer() async throws {
        let (store, context, _) = try await AcceptanceFixture.offering()
        let lifestyle = ReliefDetailViewModel(context: context, store: store,
                                              code: ReliefCode("LIFESTYLE"))
        await lifestyle.refresh()

        #expect(lifestyle.advice == .none)
        #expect(await lifestyle.acceptSuggestion() == false)
        #expect(try await store.entryDrafts(forYear: 2025).isEmpty)
    }

    @Test("the accepted figure is an ordinary entry, document requirement and all")
    func acceptedEntryIsOrdinary() async throws {
        let (_, _, model) = try await AcceptanceFixture.offering()
        #expect(await model.acceptSuggestion())

        // It appears in the Entries list because it *is* a row, and the rulebook's EPF
        // statement is owed on it like on any other claim.
        #expect(model.entries.count == 1)
        let entry = try #require(model.entries.first)
        #expect(entry.amount == Money(ringgit: 4_000))
        #expect(entry.needsDocument)
        #expect(entry.documentKinds.isEmpty)

        // And the offer is gone, because the relief is now claimed.
        #expect(model.advice == .none)
    }

    @Test("both question owners reach the screen through one list")
    func questionsMergeBothOwners() async throws {
        let store = try await PresentationFixture.store()
        try await AcceptanceFixture.seedSalariedJob(store)
        let context = PresentationFixture.context(store)
        await context.load()

        // TaxData's half: the payroll facts that block the floor. Nobody has answered them,
        // so the EPF screen asks rather than offering.
        let epf = ReliefDetailViewModel(context: context, store: store,
                                        code: .epfContribution)
        await epf.refresh()
        #expect(epf.questions == [.contribution(.nationality), .contribution(.dateOfBirth)])

        // TaxKit's half: a rulebook eligibility predicate with nothing to read.
        let disability = ReliefDetailViewModel(context: context, store: store,
                                               code: ReliefCode("DISABLED_SELF"))
        await disability.refresh()
        #expect(disability.questions == [.profile(.disabilityStatus)])
        #expect(disability.advice == .none)
    }

    @Test("a year the rulebook does not cover clears the advice it had already shown")
    func adviceIsClearedWithTheRestOfTheScreen() async throws {
        let (_, context, model) = try await AcceptanceFixture.offering()
        #expect(model.advice != .none)

        await context.switchYear(to: 2026)
        await model.refresh()
        #expect(model.advice == .none)
        #expect(model.questions.isEmpty)
    }
}
