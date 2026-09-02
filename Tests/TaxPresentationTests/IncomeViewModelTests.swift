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

    @Test("without an override the figure reaching the engine is the derived one")
    func effectiveIsDerived() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        #expect(!model.isOverridden)
        #expect(model.override == nil)
        #expect(model.isYearKnown)
        #expect(model.derivedTotal == Money(ringgit: 113_950))
        // Asserted through the projection rather than through a second copy of
        // `override ?? derived` on the view model. That copy had no production caller and
        // had already drifted from this one; the rule now lives in exactly one place, so
        // this is where the screen's figure and the engine's are checked to agree.
        #expect(try await store.project(year: model.context.year).snapshot.grossIncome
                == model.derivedTotal)
    }

    @Test("an override replaces the effective total and is visible as such")
    func overrideIsVisible() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)

        await model.saveOverride(Money(ringgit: 120_000))
        #expect(model.isOverridden)
        #expect(try await store.project(year: 2025).snapshot.grossIncome
                == Money(ringgit: 120_000))
        // The derived figure stays visible so the user can see the two disagree and decide
        // which is right — that is the whole point of showing both.
        #expect(model.derivedTotal == Money(ringgit: 113_950))

        await model.clearOverride()
        #expect(!model.isOverridden)
        #expect(try await store.project(year: 2025).snapshot.grossIncome
                == Money(ringgit: 113_950))
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
        #expect(model.sources.filter { $0.warning != nil }.count == 1)

        // The notice travels on the row it belongs to, not as a loose list the view has
        // to match up again by name.
        let flagged = try #require(model.sources.first { $0.name == "Side business" })
        #expect(flagged.warning?.contains("Side business") == true)
        #expect(flagged.warning?.contains("Form B") == true)
        #expect(model.sources.first { $0.name == "Main job" }?.warning == nil)
        #expect(model.sources.first { $0.name == "Tutoring" }?.warning == nil)
    }

    @Test("sources whose names overlap each keep their own notice")
    func warningsSurviveOverlappingNames() async throws {
        let store = try await PresentationFixture.store()
        var flat = IncomeSourceDraft(name: "Rental"); flat.kind = .rental
        _ = try await store.save(flat)
        var shop = IncomeSourceDraft(name: "Rental Penang"); shop.kind = .business
        _ = try await store.save(shop)
        let model = await Self.model(store)

        // "Rental" is a substring of "Rental Penang". Matching a flat list of warnings by
        // name — which is what the view used to do — hands one source the other's
        // compliance notice, telling the user to file the wrong form.
        let rental = try #require(model.sources.first { $0.name == "Rental" })
        let business = try #require(model.sources.first { $0.name == "Rental Penang" })
        #expect(rental.warning?.contains("rental income") == true)
        #expect(business.warning?.contains("business income") == true)
        #expect(business.warning?.hasPrefix("Rental Penang") == true)
    }

    @Test("a new record defaults into the year being viewed, not today")
    func newRecordDateIsAnchoredToTheYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)

        // The newest shipped rulebook is normally the previous assessment year, so a
        // `Date()` default pre-fills a date outside the year on screen: the record is
        // then listed under a subtotal it contributes nothing to.
        #expect(IncomeCalendar.year(of: model.newRecordDate) == model.context.year)
        #expect(model.newRecordDate == IncomeCalendar.startOfYear(model.context.year))

        let editor = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: UUID()),
                                                 today: model.newRecordDate)
        #expect(IncomeCalendar.year(of: editor.effectiveFrom) == model.context.year)
    }

    // MARK: - Ending a source

    @Test("an edited source keeps its id and updates in place")
    func editingASourceUpdatesInPlace() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Mian job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 9_000); rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)
        let model = await Self.model(store)

        let row = try #require(model.sources.first)
        let editor = IncomeRecordEditorViewModel(mode: .editSource(row.draft),
                                                 today: model.newRecordDate)
        // Seeded from the source, not blank: an edit sheet that opens empty is a rename
        // that silently clears the kind.
        #expect(editor.name == "Mian job")
        #expect(editor.kind == .employment)
        #expect(!editor.hasEndDate)

        editor.name = "Main job"
        let draft = try #require(editor.sourceDraft())
        #expect(draft.id == sourceID, "a fresh id would insert a second source")
        #expect(await model.saveSource(draft))

        // One source, renamed — not two, and its records still under it.
        #expect(model.sources.count == 1)
        #expect(model.sources.first?.name == "Main job")
        #expect(model.sources.first?.records.count == 1)
        #expect(model.derivedTotal == Money(ringgit: 108_000))
    }

    @Test("editing a source keeps the deduction answers the sheet never shows")
    func editingASourceKeepsUnshownAnswers() async throws {
        let store = try await PresentationFixture.store()
        var job = IncomeSourceDraft(name: "Main job")
        // `nil` means "not asked". A round trip that resets a real answer to nil would
        // turn "confirmed, no EPF" back into a question nobody asked.
        job.deductsEPF = true
        job.deductsSOCSO = false
        let sourceID = try await store.save(job)
        let model = await Self.model(store)

        let row = try #require(model.sources.first)
        let editor = IncomeRecordEditorViewModel(mode: .editSource(row.draft),
                                                 today: model.newRecordDate)
        editor.name = "Day job"
        #expect(await model.saveSource(try #require(editor.sourceDraft())))

        let saved = try #require(try await store.incomeSourceDrafts().first { $0.id == sourceID })
        #expect(saved.name == "Day job")
        #expect(saved.deductsEPF == true)
        #expect(saved.deductsSOCSO == false)
    }

    @Test("setting an end date stops the salary, and clearing it starts it again")
    func endingASourceReducesTheYear() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Old job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 9_000); rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)
        let model = await Self.model(store)
        #expect(model.derivedTotal == Money(ringgit: 108_000))

        // Leaving on 31 August. Without this there is no way to stop a recurring rate at
        // all, and a job the user left in September keeps paying for every year after.
        let editor = IncomeRecordEditorViewModel(
            mode: .editSource(try #require(model.sources.first).draft),
            today: model.newRecordDate)
        editor.hasEndDate = true
        editor.endedOn = Self.date(2025, 8, 31)
        #expect(await model.saveSource(try #require(editor.sourceDraft())))

        // Eight whole months, inclusive of the last day — the figure the derivation and
        // the store already agree on.
        #expect(model.derivedTotal == Money(ringgit: 72_000))
        #expect(model.sources.first?.endedOn != nil)

        // And it can be taken back off. A toggle plus a picker, rather than a bare
        // picker, is what keeps "no end date" representable.
        let reopen = IncomeRecordEditorViewModel(
            mode: .editSource(try #require(model.sources.first).draft),
            today: model.newRecordDate)
        #expect(reopen.hasEndDate)
        reopen.hasEndDate = false
        #expect(await model.saveSource(try #require(reopen.sourceDraft())))

        #expect(model.sources.first?.endedOn == nil)
        #expect(model.derivedTotal == Money(ringgit: 108_000))
    }

    @Test("an ended source stops feeding the engine, not just the screen")
    func endingASourceReachesTheProjection() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Old job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 9_000); rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)
        let model = await Self.model(store)

        let editor = IncomeRecordEditorViewModel(
            mode: .editSource(try #require(model.sources.first).draft),
            today: model.newRecordDate)
        editor.hasEndDate = true
        editor.endedOn = Self.date(2025, 8, 31)
        #expect(await model.saveSource(try #require(editor.sourceDraft())))

        #expect(try await store.project(year: 2025).snapshot.grossIncome
                == Money(ringgit: 72_000))
    }

    // MARK: - Where a new record starts

    @Test("a new record starts the day after the source's latest record, not on top of it")
    func newRecordDateFollowsTheLatestRecord() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        // Exactly what onboarding writes: a rate dated 1 January.
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000); rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)
        let model = await Self.model(store)

        // Not 1 January. Defaulting there put a second rate on the same day as the first,
        // and the derivation's tie-break — correct, and necessary for two devices to
        // agree — then decided which one the year used, arbitrarily as far as the user is
        // concerned, with both rows rendering identically.
        #expect(model.newRecordDate(forSource: sourceID) == IncomeCalendar.startOfDay(Self.date(2025, 1, 2)))
        #expect(model.occupiedDays(forSource: sourceID).count == 1)

        // A source with no records at all still starts at the year's first day.
        let fresh = try await store.save(IncomeSourceDraft(name: "New gig"))
        await model.refresh()
        #expect(model.newRecordDate(forSource: fresh)
                == IncomeCalendar.startOfYear(model.context.year))

        // An unknown source cannot pre-fill anything but the year start either.
        #expect(model.newRecordDate(forSource: UUID())
                == IncomeCalendar.startOfYear(model.context.year))
    }

    @Test("the new-record default stays inside the year on screen at both ends")
    func newRecordDateIsClamped() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        // A rate carried in from an earlier year: the day after it is in 2024, which would
        // pre-fill a date the 2025 subtotal ignores.
        var old = IncomeRecordDraft(sourceID: sourceID)
        old.amount = Money(ringgit: 8_000); old.effectiveFrom = Self.date(2024, 4, 1)
        _ = try await store.save(old)
        let model = await Self.model(store)
        #expect(model.newRecordDate(forSource: sourceID) == IncomeCalendar.startOfYear(2025))

        // And a record on 31 December must not push the default into the next year.
        var last = IncomeRecordDraft(sourceID: sourceID)
        last.amount = Money(ringgit: 9_000); last.effectiveFrom = Self.date(2025, 12, 31)
        _ = try await store.save(last)
        await model.refresh()
        #expect(model.newRecordDate(forSource: sourceID) == IncomeCalendar.endOfYear(2025))
    }

    @Test("the editor says so when a chosen date ties with an existing record")
    func collisionIsNoted() async throws {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000); rate.effectiveFrom = Self.date(2025, 1, 1)
        _ = try await store.save(rate)
        let model = await Self.model(store)

        let editor = IncomeRecordEditorViewModel(
            mode: .addRecord(sourceID: sourceID),
            today: model.newRecordDate(forSource: sourceID),
            occupiedDays: model.occupiedDays(forSource: sourceID))
        #expect(editor.dateCollisionNote == nil, "the default must not collide")

        // Same day, different time of day: comparing instants would miss this.
        editor.effectiveFrom = Self.date(2025, 1, 1)
        #expect(editor.dateCollisionNote != nil)

        // A record being edited does not collide with itself.
        let existing = try #require(model.sources.first?.records.first)
        let selfEdit = IncomeRecordEditorViewModel(
            mode: .edit(existing), today: existing.effectiveFrom,
            occupiedDays: model.occupiedDays(forSource: sourceID, excluding: existing.id))
        #expect(selfEdit.dateCollisionNote == nil)
    }

    @Test("a failed delete is reported rather than looking like a tap that missed")
    func deletesReportFailure() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)
        let model = await Self.model(store)
        let side = try #require(model.sources.first { $0.name == "Design freelance" })

        // The happy path returns true; the screen only shows a message when it does not.
        #expect(await model.deleteRecord(id: try #require(side.records.first).id))
        #expect(await model.deleteSource(id: side.id))
        // Idempotent: deleting what is already gone is a no-op, not a failure to report.
        #expect(await model.deleteSource(id: side.id))
    }

    @Test("adding a rate updates the total without a manual reload")
    func addingARateRecomputes() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        // An empty store is an unknown year, not RM 0.00 — nobody has told Relio anything.
        #expect(model.derivedTotal == nil)

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

    @Test("a year the timeline never reaches is unknown, not a confident RM 0.00")
    func emptyYear() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.model(store)
        #expect(model.sources.isEmpty)
        // nil, not zero. The screen renders "Not recorded" from this: RM 0.00 under a
        // footer saying Relio added the records up is a claim that the household earned
        // nothing, made about a year nobody has said anything about.
        #expect(model.derivedTotal == nil)
        #expect(!model.isYearKnown)
        #expect(!model.isOverridden)
        // And it agrees with what the engine is handed, because both come from
        // `IncomeDerivation.knownAnnualGross`.
        #expect(try await store.project(year: model.context.year).snapshot.grossIncome == nil)
    }

    @Test("a 2025-only timeline leaves YA2024 unknown on this screen, not RM 0.00")
    func unknownYearIsNotZero() async throws {
        let store = try await PresentationFixture.store()
        try await Self.seedWorkedExample(store)

        let known = PresentationFixture.context(store, year: 2025)
        await known.load()
        let knownModel = IncomeViewModel(context: known, store: store)
        await knownModel.refresh()
        #expect(knownModel.isYearKnown)
        #expect(knownModel.derivedTotal == Money(ringgit: 113_950))

        let earlier = PresentationFixture.context(store, year: 2024)
        await earlier.load()
        let earlierModel = IncomeViewModel(context: earlier, store: store)
        await earlierModel.refresh()
        // The sources still list — they exist — but the year has no figure. This is the
        // distinction the branch established one layer down, and it must survive up here:
        // Home renders no tax figures for 2024, and this screen must not contradict it.
        #expect(!earlierModel.isYearKnown)
        #expect(earlierModel.derivedTotal == nil)
        #expect(!earlierModel.sources.isEmpty)
        #expect(try await store.project(year: 2024).snapshot.grossIncome == nil)
    }
}

@Suite("IncomeRecordEditorViewModel") @MainActor struct IncomeRecordEditorViewModelTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        IncomeViewModelTests.date(y, m, d)
    }

    @Test("a new source needs a name")
    func sourceNeedsAName() {
        let editor = IncomeRecordEditorViewModel(mode: .addSource, today: Self.date(2025, 1, 1))
        #expect(!editor.canSave)
        editor.name = "   "
        #expect(!editor.canSave, "whitespace is not a name")
        editor.name = "Main job"
        #expect(editor.canSave)
    }

    @Test("a record needs an amount above zero")
    func recordNeedsAnAmount() {
        let editor = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: UUID()),
                                                 today: Self.date(2025, 1, 1))
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
        let editor = IncomeRecordEditorViewModel(mode: .edit(record), today: Self.date(2025, 1, 1))
        // "RM 9,500.00" in a text field means deleting the prefix before you can type.
        #expect(editor.amountText == "9500.00")
        #expect(editor.shape == .oneOff)
    }

    @Test("editing produces a draft with the same id, so it updates in place")
    func editKeepsItsIdentity() {
        var record = IncomeRecordDraft(sourceID: UUID())
        record.amount = Money(ringgit: 8_000)
        let editor = IncomeRecordEditorViewModel(mode: .edit(record), today: Self.date(2025, 1, 1))
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

/// Spec §11.6 asks for an undo toast on every destructive action. Income had none, on
/// either of its two deletes, against the figure every tax number in the app derives from.
@Suite("Income undo") @MainActor struct IncomeUndoTests {

    static func seeded() async throws -> (TaxStore, IncomeViewModel, UUID, UUID) {
        let store = try await PresentationFixture.store()
        let sourceID = try await store.seedPrimaryEmployment(
            name: "Main job",
            monthlyRate: Money(ringgit: 8_000),
            effectiveFrom: IncomeViewModelTests.date(2025, 1, 1))
        var raise = IncomeRecordDraft(sourceID: sourceID)
        raise.amount = Money(ringgit: 9_000)
        raise.effectiveFrom = IncomeViewModelTests.date(2025, 7, 1)
        let raiseID = try await store.save(raise)
        let model = await IncomeViewModelTests.model(store)
        return (store, model, sourceID, raiseID)
    }

    @Test("deleting a source offers it back by name")
    func deletingASourceIsUndoable() async throws {
        let (_, model, sourceID, _) = try await Self.seeded()
        #expect(model.lastDeleted == nil)

        await model.deleteSource(id: sourceID)
        #expect(model.lastDeleted == .source(sourceID, name: "Main job"))
        // The name is captured before the delete; afterwards the source is gone from the
        // drafts and the toast would have nothing to show.
        #expect(model.lastDeleted?.message == "Deleted Main job")
        #expect(model.sources.isEmpty)

        await model.undoDelete()
        #expect(model.lastDeleted == nil)
        #expect(model.sources.count == 1)
    }

    /// The swipe with no confirmation. This is the one an undo matters most for.
    @Test("deleting a record offers it back, and the total returns")
    func deletingARecordIsUndoable() async throws {
        let (_, model, _, raiseID) = try await Self.seeded()
        let before = model.derivedTotal

        await model.deleteRecord(id: raiseID)
        #expect(model.lastDeleted == .record(raiseID))
        #expect(model.derivedTotal != before)

        await model.undoDelete()
        #expect(model.derivedTotal == before)
    }

    @Test("dismissing the toast leaves the delete standing")
    func clearingUndoDoesNotRestore() async throws {
        let (_, model, sourceID, _) = try await Self.seeded()
        await model.deleteSource(id: sourceID)
        model.clearUndo()
        #expect(model.lastDeleted == nil)
        #expect(model.sources.isEmpty)
    }
}
