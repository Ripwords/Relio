import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

@Suite("Money parsing") struct MoneyParsingTests {

    @Test("common shapes of a typed amount parse exactly")
    func parsesTypedAmounts() {
        #expect(MoneyParsing.money(from: "1820") == Money(ringgit: 1_820))
        #expect(MoneyParsing.money(from: "1820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "1,820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "RM 1,820.50") == Money(sen: 182_050))
        #expect(MoneyParsing.money(from: "  1820.5  ") == Money(sen: 182_050))
    }

    @Test("a third decimal place is rounded half-up, not truncated")
    func roundsToSen() {
        // Money(ringgit:) rounds half-up at the boundary; this pins that the parser
        // hands it a Decimal rather than doing its own lossy conversion.
        #expect(MoneyParsing.money(from: "10.005") == Money(sen: 1_001))
        #expect(MoneyParsing.money(from: "10.004") == Money(sen: 1_000))
    }

    @Test("nonsense does not parse")
    func rejectsNonsense() {
        #expect(MoneyParsing.money(from: "") == nil)
        #expect(MoneyParsing.money(from: "abc") == nil)
        #expect(MoneyParsing.money(from: "RM") == nil)
        #expect(MoneyParsing.money(from: "1.2.3") == nil)
    }
}

@Suite("EntryEditorViewModel") @MainActor struct EntryEditorViewModelTests {

    static func editor(_ store: TaxStore, editing id: UUID? = nil) async -> EntryEditorViewModel {
        let context = PresentationFixture.context(store)
        await context.load()
        let model = EntryEditorViewModel(context: context, store: store, editing: id)
        await model.load()
        return model
    }

    @Test("a new entry saves and appears in the year")
    func createsAnEntry() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.editor(store)

        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320.50"
        model.vendor = "Kinokuniya"
        #expect(model.canSave)

        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025)
            .first { $0.vendor == "Kinokuniya" }
        #expect(saved?.amount == Money(sen: 32_050))
        #expect(saved?.code == ReliefCode("LIFESTYLE"))
    }

    @Test("editing an existing entry updates it in place")
    func editsInPlace() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)

        let model = await Self.editor(store, editing: existing.id)
        #expect(model.selectedCode == existing.code)
        #expect(MoneyParsing.money(from: model.amountText) == existing.amount)

        let countBefore = try await store.entryDrafts(forYear: 2025).count
        model.amountText = "999"
        #expect(await model.save())

        let after = try await store.entryDrafts(forYear: 2025)
        #expect(after.count == countBefore, "editing must not insert a second row")
        #expect(after.first { $0.id == existing.id }?.amount == Money(ringgit: 999))
    }

    @Test("automatic reliefs are not offered")
    func automaticRelievesAreFilteredOut() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.editor(store)

        let offered = Set(model.availableCodes.map(\.code))
        // An amount logged against an automatic relief is silently discarded by the
        // evaluator, which grants the full cap from household facts instead. Plan 1
        // parked this; the fix is to make the entry impossible to create.
        #expect(!offered.contains(ReliefCode("SELF_AND_DEPENDENTS")))
        #expect(!offered.isEmpty)

        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        for rule in ruleSet.allReliefs where rule.automatic {
            #expect(!offered.contains(rule.code), "\(rule.code) is automatic and must not be offered")
        }
    }

    @Test("an entry that already exists against an automatic relief opens read-only")
    func existingAutomaticEntryIsReadOnly() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("SELF_AND_DEPENDENTS"),
                               amount: Money(ringgit: 9_000))
        draft.vendor = "Imported"
        let id = try await store.save(draft)

        let model = await Self.editor(store, editing: id)
        #expect(model.isReadOnly)
        #expect(model.readOnlyReason != nil)
        #expect(!model.canSave)
    }

    @Test("an invalid amount blocks saving and says why")
    func validation() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")

        model.amountText = ""
        #expect(!model.canSave)
        model.amountText = "abc"
        #expect(!model.canSave)
        #expect(model.validationError != nil)
        model.amountText = "0"
        #expect(!model.canSave)
        model.amountText = "-5"
        // A typo'd minus must not quietly reduce someone's relief. See the plan note on
        // net SSPN deposits for the case this deliberately cannot express.
        #expect(!model.canSave)

        model.amountText = "12.34"
        #expect(model.canSave)
        #expect(model.validationError == nil)
    }

    @Test("saving with no relief chosen is blocked")
    func codeIsRequired() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.amountText = "100"
        model.selectedCode = nil
        #expect(!model.canSave)
    }

    @Test("a relief that excludes the taxpayer forces a claimant choice")
    func claimantIsRequiredWhereTheRuleExcludesSelf() async throws {
        let store = try await PresentationFixture.store()
        var mother = DependentDraft(id: UUID(), name: "Mother")
        mother.kind = .parent
        _ = try await store.save(mother)

        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("PARENTS_MEDICAL")
        model.amountText = "1200"

        // PARENTS_MEDICAL admits only .parent and .grandparent. Saved with the default
        // .individual it is refused by the engine and the user loses the claim with no
        // explanation, so the editor refuses first and says why.
        #expect(model.admittedClaimants == [.parent, .grandparent])
        #expect(model.claimant == .individual)
        #expect(!model.canSave)
        #expect(model.validationError != nil)

        model.claimant = .parent
        #expect(model.canSave)
    }

    @Test("a relief that admits the taxpayer saves without touching the claimant")
    func claimantDefaultsWhereTheRuleAdmitsSelf() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320"
        // LIFESTYLE admits self, spouse and child. The default is already valid, so the
        // picker must not become a speed bump on the commonest entry in the app.
        #expect(model.admittedClaimants.contains(.individual))
        #expect(model.canSave)
    }

    @Test("a dependent may be named but is never required")
    func dependentIsOptionalAnnotation() async throws {
        let store = try await PresentationFixture.store()
        var farah = DependentDraft(id: UUID(), name: "Farah")
        farah.dateOfBirth = Date(timeIntervalSince1970: 1_253_491_200)
        _ = try await store.save(farah)

        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320"
        model.claimant = .child

        // Every per-dependent relief is automatic and therefore not offerable, so no
        // entry the user can create needs a dependent for the engine's sake. Naming one
        // is for their own record.
        #expect(model.allowsDependent)
        #expect(model.canSave, "no dependent named, and that is fine")
        #expect(model.availableDependents.contains { $0.id == farah.id })

        model.dependentID = farah.id
        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025).first { $0.dependentID == farah.id }
        #expect(saved?.claimant == .child)
    }

    @Test("no offerable relief has a per-dependent cap")
    func noOfferableReliefIsPerDependent() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        // Pins the fact this design rests on. If a future Budget ships a manually-logged
        // per-dependent relief, this fails and the dependent field must become required
        // for it.
        for option in model.availableCodes {
            if case .perDependent = ruleSet.relief(for: option.code)?.cap {
                Issue.record("\(option.code) is offerable and per-dependent")
            }
        }
    }

    @Test("a same-session duplicate warns but does not block")
    func duplicateWarning() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025)
            .first { $0.code == ReliefCode("LIFESTYLE") })

        let model = await Self.editor(store)
        model.selectedCode = existing.code
        model.amountText = existing.amount.formattedForEditing()
        model.vendor = existing.vendor
        model.spentOn = existing.spentOn
        await model.checkForDuplicate()

        #expect(model.duplicateWarning != nil)
        // Warns, never blocks: two identical receipts from the same shop on the same day
        // are unusual but real, and refusing the second would make the app wrong about
        // the user's own money.
        #expect(model.canSave)

        model.amountText = "12345"
        await model.checkForDuplicate()
        #expect(model.duplicateWarning == nil)
    }

    @Test("editing an entry does not flag itself as its own duplicate")
    func editingIsNotItsOwnDuplicate() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)

        let model = await Self.editor(store, editing: existing.id)
        await model.checkForDuplicate()
        #expect(model.duplicateWarning == nil)
    }

    @Test("deleting is undoable")
    func deleteAndUndo() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)
        let model = await Self.editor(store, editing: existing.id)

        await model.delete()
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } == nil)

        // Spec §11.6: every destructive action is undoable, on all platforms.
        await model.undoDelete()
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } != nil)
    }

    @Test("saving refreshes the shared evaluation")
    func saveRefreshesTheContext() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let context = PresentationFixture.context(store)
        await context.load()
        let before = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)

        let model = EntryEditorViewModel(context: context, store: store, editing: nil)
        await model.load()
        model.selectedCode = ReliefCode("SSPN")
        model.amountText = "750"
        #expect(await model.save())

        // Otherwise Home keeps showing the old headline until something else reloads it,
        // and the user sees their entry vanish into nothing.
        let after = try #require(context.result?.assessment(for: ReliefCode("SSPN"))?.claimed)
        #expect(after == before + Money(ringgit: 750))
    }
}
