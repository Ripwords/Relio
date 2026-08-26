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

    @Test("an unrepresentably large amount fails to parse rather than crashing")
    func rejectsAmountsOutOfRange() {
        // Money(ringgit:) traps via `precondition` outside Int's range, and
        // validationError re-parses on every keystroke — so this must fail to parse,
        // not reach that precondition while the user is still typing.
        #expect(MoneyParsing.money(from: "12345678901234567890") == nil)
    }

    @Test("an embedded minus does not silently truncate the amount")
    func rejectsEmbeddedMinus() {
        // Decimal(string:) stops at the first character it cannot parse rather than
        // failing outright, so a naive character-class check that merely allows "-"
        // anywhere lets "5-3" become RM 5.00 and "1-2.5" become RM 1.00 — a wrong
        // amount, which is worse than no amount. Negatives are refused by validation
        // anyway, so "-" is rejected outright rather than only checked for position.
        #expect(MoneyParsing.money(from: "5-3") == nil)
        #expect(MoneyParsing.money(from: "1-2.5") == nil)
        #expect(MoneyParsing.money(from: "-5") == nil)
    }

    @Test("a digit Decimal cannot read does not silently truncate the amount")
    func rejectsNonASCIIDigits() {
        // `Character.isNumber` is true for every digit Unicode knows, and
        // `Decimal(string:)` reads none of them — so a check of `isNumber` alone lets
        // "12٣4" (an Arabic-Indic 3, one keyboard-switch away on a Malaysian phone)
        // become RM 12.00 and "5٣" become RM 5.00. Identical failure to the "5-3" case
        // above, from the identical cause.
        #expect(MoneyParsing.money(from: "12٣4") == nil)
        #expect(MoneyParsing.money(from: "5٣") == nil)
        #expect(MoneyParsing.money(from: "١٢٣") == nil)
        // Vulgar fractions and enclosed digits are `isNumber` too.
        #expect(MoneyParsing.money(from: "1½") == nil)
        #expect(MoneyParsing.money(from: "③") == nil)
        // ASCII digits still parse, which is the whole point of the tightening.
        #expect(MoneyParsing.money(from: "1234") == Money(ringgit: 1_234))
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

    @Test("a sub-limit with no claimant restriction of its own inherits its parent's")
    func subLimitInheritsParentClaimant() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("PARENTS_CHECKUP")
        model.amountText = "500"

        // PARENTS_CHECKUP's own eligibility is nil in ya-2025.json; the restriction to
        // parent and grandparent lives on its parent, PARENTS_MEDICAL. Without
        // inheritance this reads as "no restriction", the entry saves as .individual,
        // and it is refused outright by the engine — the identical silent RM 8,000 loss
        // the PARENTS_MEDICAL guard was written to prevent, one level down the tree.
        #expect(model.admittedClaimants == [.parent, .grandparent])
        #expect(model.claimant == .individual)
        #expect(!model.canSave)
        #expect(model.validationError != nil)

        model.claimant = .parent
        #expect(model.canSave)
    }

    @Test("a sub-limit under a relief that admits self still admits self")
    func subLimitInheritsSelfAdmittingParent() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("MEDICAL_CHECKUP")
        model.amountText = "150"

        // MEDICAL_CHECKUP's own eligibility is nil too; its parent MEDICAL_SERIOUS
        // admits self, spouse and child. Inheritance must not turn every sub-limit into
        // a speed bump — only the ones whose parent actually restricts the claimant.
        #expect(model.admittedClaimants == [.individual, .spouse, .child])
        #expect(model.canSave)
    }

    @Test("admittedClaimants for a claimant-restricted code is correct even when the code is not offered")
    func admittedClaimantsIndependentOfAvailableCodes() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)

        // CHILD_UNDER_18 is automatic, so it is filtered out of availableCodes entirely
        // — but the claimant restriction must still be readable directly from the
        // rulebook via admittedClaimantsByCode, not silently reported as "no
        // restriction" merely because the code isn't in that UI-filtered list.
        model.selectedCode = ReliefCode("CHILD_UNDER_18")
        #expect(model.admittedClaimants == [.child])
    }

    @Test("an automatic code set directly on a new entry blocks saving with a reason")
    func automaticCodeSetDirectlyBlocksSaving() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let model = await Self.editor(store)

        // Bypassing the picker entirely: selectedCode is a plain settable property, and
        // SELF_AND_DEPENDENTS is automatic and therefore excluded from availableCodes.
        // The guard must come from the rulebook via context.rule(for:), not from
        // membership in that UI-filtered list, or it silently vanishes for exactly the
        // codes it exists to catch.
        model.selectedCode = ReliefCode("SELF_AND_DEPENDENTS")
        model.amountText = "9000"

        #expect(!model.canSave)
        #expect(model.validationError != nil)
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

    @Test("CHILDCARE admits a dependent even though its predicate carries no claimant")
    func childcareAllowsDependentViaDependentFact() async throws {
        let store = try await PresentationFixture.store()
        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("CHILDCARE")
        model.amountText = "1000"

        // CHILDCARE's eligibility is dependentAge(max: 6) with no .claimant(in:) node at
        // all, so the old claimant-only check reported allowsDependent == false and the
        // dependent field never appeared for the one relief where naming the child is
        // the entire point.
        #expect(model.allowsDependent)
    }

    @Test("editing a CHILDCARE entry preserves which child it names")
    func editingChildcarePreservesDependent() async throws {
        let store = try await PresentationFixture.store()
        var aiman = DependentDraft(id: UUID(), name: "Aiman")
        aiman.dateOfBirth = Date(timeIntervalSince1970: 1_600_000_000)
        _ = try await store.save(aiman)

        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("CHILDCARE"), amount: Money(ringgit: 2_000))
        draft.dependentID = aiman.id
        draft.vendor = "Tadika Ceria"
        let id = try await store.save(draft)

        let model = await Self.editor(store, editing: id)
        #expect(model.dependentID == aiman.id)

        // Re-saving unchanged must not erase which child the claim is for. The engine
        // ignores dependentID on CHILDCARE's fixed cap, so there is no tax impact — but
        // silently dropping the user's own record on every re-save of a synced entry
        // defeats the entire purpose of the field.
        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025).first { $0.id == id }
        #expect(saved?.dependentID == aiman.id)
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

    @Test("switching off an automatic relief unlocks the form")
    func readOnlyFollowsTheSelectedCode() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("SELF_AND_DEPENDENTS"),
                               amount: Money(ringgit: 9_000))
        draft.vendor = "Imported"
        let id = try await store.save(draft)

        let model = await Self.editor(store, editing: id)
        #expect(model.isReadOnly)

        // The obvious repair for an entry that opened read-only is to point it at a
        // relief that can actually hold it. A flag assigned once in `load()` leaves the
        // form permanently unsaveable, still citing SELF_AND_DEPENDENTS — a dead end the
        // user cannot escape without abandoning the entry.
        model.selectedCode = ReliefCode("LIFESTYLE")
        model.amountText = "320"

        #expect(!model.isReadOnly)
        #expect(model.readOnlyReason == nil)
        #expect(model.canSave)
        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025).first { $0.id == id }
        #expect(saved?.code == ReliefCode("LIFESTYLE"))
        #expect(saved?.amount == Money(ringgit: 320))
    }

    @Test("switching to a relief with no dependent field drops the dependent")
    func dependentIsClearedWhenTheNewCodeCannotShowIt() async throws {
        let store = try await PresentationFixture.store()
        var aiman = DependentDraft(id: UUID(), name: "Aiman")
        aiman.dateOfBirth = Date(timeIntervalSince1970: 1_600_000_000)
        _ = try await store.save(aiman)

        let model = await Self.editor(store)
        model.selectedCode = ReliefCode("CHILDCARE")
        model.amountText = "2000"
        model.dependentID = aiman.id
        #expect(model.allowsDependent)

        // SSPN admits no dependent-ish claimant and turns on no dependent fact, so the
        // picker hides the field entirely.
        model.selectedCode = ReliefCode("SSPN")
        #expect(!model.allowsDependent)
        // `dependentID` is hashed into the dedupe key. Kept invisibly, it makes two
        // otherwise-identical SSPN deposits hash differently, and the sweep can never
        // collapse them however many times it runs.
        #expect(model.dependentID == nil)

        #expect(await model.save())
        let saved = try #require(try await store.entryDrafts(forYear: 2025)
            .first { $0.code == ReliefCode("SSPN") })
        #expect(saved.dependentID == nil)
    }

    @Test("re-saving an untouched CHILDCARE entry keeps the child it names")
    func dependentSurvivesWhenTheCodeIsNotTouched() async throws {
        let store = try await PresentationFixture.store()
        var aiman = DependentDraft(id: UUID(), name: "Aiman")
        aiman.dateOfBirth = Date(timeIntervalSince1970: 1_600_000_000)
        _ = try await store.save(aiman)

        var draft = EntryDraft(id: UUID(), year: 2025,
                               code: ReliefCode("CHILDCARE"), amount: Money(ringgit: 2_000))
        draft.dependentID = aiman.id
        draft.vendor = "Tadika Ceria"
        let id = try await store.save(draft)

        let model = await Self.editor(store, editing: id)
        #expect(model.dependentID == aiman.id)

        // The other direction of the same rule, and the case Task 15 fixed: clearing on
        // a code *change* must not become clearing on every save. Editing the amount and
        // saving leaves the code alone, so the child survives.
        model.amountText = "2500"
        #expect(await model.save())
        let saved = try await store.entryDrafts(forYear: 2025).first { $0.id == id }
        #expect(saved?.dependentID == aiman.id)
        #expect(saved?.amount == Money(ringgit: 2_500))

        // Re-assigning the same code is not a change either.
        model.selectedCode = ReliefCode("CHILDCARE")
        #expect(model.dependentID == aiman.id)
    }

    @Test("saving after deleting does not resurrect the entry")
    func deleteBlocksSaving() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025).first)
        let model = await Self.editor(store, editing: existing.id)
        #expect(model.canSave)

        await model.delete()

        // `TaxStore.save` clears `deletedAt` by design (it is how a merge loser comes
        // back), so a save after a delete revives the row the user just deleted. Left to
        // the view, that rule is invisible to `swift test` and has to be re-implemented
        // on every platform.
        #expect(!model.canSave)
        #expect(await model.save() == false)
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } == nil)

        // Undo restores the ability to save along with the entry.
        await model.undoDelete()
        #expect(model.canSave)
        #expect(await model.save())
        #expect(try await store.entryDrafts(forYear: 2025).first { $0.id == existing.id } != nil)
    }

    @Test("the duplicate warning does not outlive the figures it quotes")
    func duplicateWarningIsClearedOnEdit() async throws {
        let store = try await PresentationFixture.store()
        try await PresentationFixture.seedTypicalHousehold(store)
        let existing = try #require(try await store.entryDrafts(forYear: 2025)
            .first { $0.code == ReliefCode("LIFESTYLE") })

        func warned() async -> EntryEditorViewModel {
            let model = await Self.editor(store)
            model.selectedCode = existing.code
            model.amountText = existing.amount.formattedForEditing()
            model.vendor = existing.vendor
            model.spentOn = existing.spentOn
            await model.checkForDuplicate()
            return model
        }

        // The warning names a specific amount ("You already logged RM 1,700.00…"). It
        // must not still be on screen once that amount is no longer what the user typed
        // — a stale warning about a figure that is not in the field reads as the app
        // being wrong about their money.
        let onAmount = await warned()
        #expect(onAmount.duplicateWarning != nil)
        onAmount.amountText = "999"
        #expect(onAmount.duplicateWarning == nil, "editing the amount must clear it")

        let onVendor = await warned()
        onVendor.vendor = "Somewhere else"
        #expect(onVendor.duplicateWarning == nil, "editing the vendor must clear it")

        let onDate = await warned()
        onDate.spentOn = Date(timeIntervalSince1970: 1_700_000_000)
        #expect(onDate.duplicateWarning == nil, "changing the date must clear it")

        let onCode = await warned()
        onCode.selectedCode = ReliefCode("SSPN")
        #expect(onCode.duplicateWarning == nil, "changing the relief must clear it")
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
