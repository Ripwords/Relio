import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("IncomeViewModel") @MainActor struct IncomeViewModelTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func model(_ store: TaxStore) async -> IncomeViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = IncomeViewModel(context: context, store: store)
        await model.refresh()
        return model
    }

    static func seedWorkedExample(_ store: TaxStore) async throws {
        let jobID = try await store.save(IncomeSourceDraft(name: "Main job"))
        for (ringgit, from) in [(Decimal(8_000), date(2025, 1, 1)),
                                (Decimal(9_500), date(2025, 4, 15))] {
            var rate = IncomeRecordDraft(sourceID: jobID)
            rate.amount = Money(ringgit: ringgit); rate.effectiveFrom = from
            _ = try await store.save(rate)
        }
        var side = IncomeSourceDraft(name: "Design freelance"); side.kind = .occasional
        let sideID = try await store.save(side)
        for (ringgit, on) in [(Decimal(1_800), date(2025, 3, 14)),
                              (Decimal(2_400), date(2025, 7, 2)),
                              (Decimal(950), date(2025, 11, 9))] {
            var payment = IncomeRecordDraft(sourceID: sideID)
            payment.shape = .oneOff; payment.amount = Money(ringgit: ringgit)
            payment.effectiveFrom = on
            _ = try await store.save(payment)
        }
    }

    @Test("sources carry their own subtotals and sum to the derived total")
    func subtotals() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        #expect(model.sources.count == 2)
        #expect(model.derivedTotal == Money(ringgit: 113_950))
        #expect(model.sources.reduce(Money.zero) { $0 + $1.total } == model.derivedTotal)
        #expect(model.sources.first { $0.name == "Design freelance" }?.total
                == Money(ringgit: 5_150))
    }

    @Test("without an override the effective total is the derived one")
    func effectiveIsDerived() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        #expect(!model.isOverridden)
        #expect(model.effectiveTotal == model.derivedTotal)
    }

    @Test("an override replaces the effective total and is visible as such")
    func overrideIsVisible() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        await model.saveOverride(Money(ringgit: 120_000))
        #expect(model.isOverridden)
        #expect(model.effectiveTotal == Money(ringgit: 120_000))
        // The derived figure stays visible so the user can see the two disagree and decide
        // which is right — that is the whole point of showing both.
        #expect(model.derivedTotal == Money(ringgit: 113_950))

        await model.clearOverride()
        #expect(!model.isOverridden)
        #expect(model.effectiveTotal == Money(ringgit: 113_950))
    }

    @Test("the override reads back as plain digits, so the field can show what is in force")
    func overrideEditingText() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        #expect(model.overrideEditingText.isEmpty)
        await model.saveOverride(Money(ringgit: 120_000))
        // Plain digits, not `RM 120,000.00`: the screen puts this straight back into an
        // editable field, and a blank field under a footer saying an override is in force
        // tells the user two contradictory things at once.
        #expect(model.overrideEditingText == "120000.00")

        await model.clearOverride()
        #expect(model.overrideEditingText.isEmpty)
    }

    @Test("saving an override refreshes the shared evaluation")
    func overrideRefreshesTheContext() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        await model.saveOverride(Money(ringgit: 120_000))
        // Otherwise Home keeps showing tax figures computed from the old income.
        #expect(model.context.result?.chargeableIncome != nil)
        #expect(model.context.result?.estimatedTax != nil)
    }

    @Test("business and rental sources are flagged, employment and occasional are not")
    func scopeWarnings() async throws {
        let store = try await PresentationFixture.store()
        var shop = IncomeSourceDraft(name: "Side business"); shop.kind = .business
        _ = try await store.save(shop)
        let job = IncomeSourceDraft(name: "Main job")
        _ = try await store.save(job)
        var gig = IncomeSourceDraft(name: "Tutoring"); gig.kind = .occasional
        _ = try await store.save(gig)
        let model = await Self.model(store)

        // Occasional work is ITA 1967 §4(f) and belongs on Form BE — it must NOT be
        // flagged, or the warning becomes noise the user learns to ignore.
        #expect(model.sources.first { $0.name == "Side business" }?.needsScopeWarning == true)
        #expect(model.sources.first { $0.name == "Main job" }?.needsScopeWarning == false)
        #expect(model.sources.first { $0.name == "Tutoring" }?.needsScopeWarning == false)
        #expect(model.outOfScopeWarnings.count == 1)
    }

    @Test("adding a rate updates the total without a manual reload")
    func addingARateRecomputes() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.derivedTotal == Money.zero)

        let sourceID = try #require(await model.addSource(IncomeSourceDraft(name: "Main job")))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2025, 1, 1)
        await model.addRecord(rate)

        #expect(model.derivedTotal == Money(ringgit: 96_000))
    }

    @Test("adding a record against a source that does not exist fails, leaving the total unchanged")
    func addingARecordForAnUnknownSourceFails() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        let before = model.derivedTotal

        var orphan = IncomeRecordDraft(sourceID: UUID())
        orphan.amount = Money(ringgit: 5_000)
        orphan.effectiveFrom = Self.date(2025, 6, 1)
        let succeeded = await model.addRecord(orphan)

        // `IncomeStoreError.unknownIncomeSource` must surface as a clear failure, not a
        // save that silently drops the record and understates income.
        #expect(!succeeded)
        #expect(model.derivedTotal == before)
    }

    @Test("deleting a record lowers the total")
    func deletingRecomputes() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        let side = try #require(model.sources.first { $0.name == "Design freelance" })
        let payment = try #require(side.records.first)

        await model.deleteRecord(id: payment.id)
        #expect(model.derivedTotal == Money(ringgit: 113_950) - Money(ringgit: 1_800))
    }

    @Test("a year with no income reports zero without crashing")
    func emptyYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.sources.isEmpty)
        #expect(model.derivedTotal == Money.zero)
        #expect(!model.isOverridden)
    }
}

@Suite("IncomeRecordEditorViewModel") @MainActor struct IncomeRecordEditorViewModelTests {

    @Test("a new source needs a name")
    func sourceNeedsAName() {
        let editor = IncomeRecordEditorViewModel(mode: .addSource)
        #expect(!editor.canSave)
        editor.name = "   "
        #expect(!editor.canSave, "whitespace is not a name")
        editor.name = "Main job"
        #expect(editor.canSave)
    }

    @Test("a record needs an amount above zero")
    func recordNeedsAnAmount() {
        let editor = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: UUID()))
        #expect(!editor.canSave)
        editor.amountText = "abc"
        #expect(!editor.canSave)
        #expect(editor.validationError != nil)
        editor.amountText = "0"
        #expect(!editor.canSave)
        editor.amountText = "8000"
        #expect(editor.canSave)
        #expect(editor.validationError == nil)
    }

    @Test("editing loads the record as plain digits, not display format")
    func editingLoadsPlainDigits() {
        var record = IncomeRecordDraft(sourceID: UUID())
        record.amount = Money(sen: 950_000)
        record.shape = .oneOff
        let editor = IncomeRecordEditorViewModel(mode: .edit(record))
        // "RM 9,500.00" in a text field means deleting the prefix before you can type.
        #expect(editor.amountText == "9500.00")
        #expect(editor.shape == .oneOff)
    }

    @Test("editing produces a draft with the same id, so it updates in place")
    func editKeepsItsIdentity() {
        var record = IncomeRecordDraft(sourceID: UUID())
        record.amount = Money(ringgit: 8_000)
        let editor = IncomeRecordEditorViewModel(mode: .edit(record))
        editor.amountText = "9500"
        let produced = editor.recordDraft()
        #expect(produced?.id == record.id)
        #expect(produced?.amount == Money(ringgit: 9_500))
    }

    @Test("the kind footnote tells the truth about each kind")
    func kindFootnotes() {
        // Occasional work is Form BE and Relio handles it — saying otherwise would make
        // the caveat noise. Business and rental must say the estimate will be too high.
        #expect(!IncomeRecordEditorViewModel.footnote(for: .occasional).contains("Form B "))
        #expect(IncomeRecordEditorViewModel.footnote(for: .business).contains("Form B"))
        #expect(IncomeRecordEditorViewModel.footnote(for: .rental).contains("deductible"))
        for kind in IncomeKind.allCases {
            #expect(!IncomeRecordEditorViewModel.footnote(for: kind).isEmpty)
            #expect(!IncomeRecordEditorViewModel.label(for: kind).isEmpty)
        }
    }
}
