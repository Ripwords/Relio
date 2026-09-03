import Foundation
import Observation
import TaxKit
import TaxData

public struct ReliefOption: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    /// Claimants the rulebook admits for this relief. Empty means it places no
    /// restriction, so the taxpayer's own claim is fine.
    public var admittedClaimants: [Claimant]
    public var id: ReliefCode { code }
}

public struct DependentOption: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
}

@MainActor
@Observable
public final class EntryEditorViewModel {

    /// The relief being claimed.
    ///
    /// A plain settable property, and every guard in this type derives from its current
    /// value rather than from what `load()` happened to see — see `readOnlyReason`.
    /// Changing it clears two pieces of state that were about the *old* code: the
    /// duplicate warning, and a dependent the new code cannot even show.
    public var selectedCode: ReliefCode? {
        get { storedSelectedCode }
        set {
            guard newValue != storedSelectedCode else { return }
            storedSelectedCode = newValue
            duplicateWarning = nil
            // `dependentID` is a component of the dedupe key. A relief whose editor
            // cannot display the field — SSPN, LIFE_INSURANCE — must not carry one
            // invisibly: two otherwise-identical entries would hash differently and the
            // sweep could never collapse them, so the duplicate would survive forever.
            //
            // Only on a *change*, which is what preserves the case Task 15 fixed:
            // `load()` assigns the code before the dependent, and re-saving an untouched
            // CHILDCARE entry never reassigns the code at all, so the child it names
            // survives the round trip.
            if !allowsDependent { dependentID = nil }
        }
    }

    public var amountText: String {
        get { storedAmountText }
        set {
            guard newValue != storedAmountText else { return }
            storedAmountText = newValue
            duplicateWarning = nil
        }
    }

    public var vendor: String {
        get { storedVendor }
        set {
            guard newValue != storedVendor else { return }
            storedVendor = newValue
            duplicateWarning = nil
        }
    }

    public var spentOn: Date? {
        get { storedSpentOn }
        set {
            guard newValue != storedSpentOn else { return }
            storedSpentOn = newValue
            duplicateWarning = nil
        }
    }

    public var claimant: Claimant = .individual
    public var dependentID: UUID?
    public var note: String = ""

    private var storedSelectedCode: ReliefCode?
    private var storedAmountText: String = ""
    private var storedVendor: String = ""
    private var storedSpentOn: Date?

    public private(set) var availableCodes: [ReliefOption] = []
    public private(set) var availableDependents: [DependentOption] = []

    private let context: YearContext
    private let store: TaxStore
    private let editingID: UUID?
    private var deletedID: UUID?
    /// The amount this editor opened on, or zero for a new entry. Subtracted from the
    /// evaluation's `claimed` in `capGuidance`, which counts the entry being edited.
    private var originalAmount: Money = .zero
    /// Every code's admitted claimants, inherited down from the nearest ancestor that
    /// declares its own `.claimant(in:)` — built once per `load()` from `context.ruleSet`
    /// and covering every code in the rulebook, not just the offerable ones.
    ///
    /// This is the authority `admittedClaimants` and `validationError` read from.
    /// `availableCodes` is a UI-filtered subset (automatic codes excluded); deriving the
    /// claimant restriction from membership in that list — as this used to — reads
    /// "not in the list" as "no restriction", which is exactly backwards for an
    /// automatic code a caller sets on `selectedCode` directly, or for a sub-limit whose
    /// own predicate is empty because the restriction lives on its parent.
    private var admittedClaimantsByCode: [ReliefCode: [Claimant]] = [:]

    public init(context: YearContext, store: TaxStore, editing id: UUID?) {
        self.context = context
        self.store = store
        self.editingID = id
    }

    /// Opens a new entry with a relief and a figure already in it.
    ///
    /// Set before `load()`, and it survives: `load()` only assigns these two fields when it
    /// opened against an existing entry, and a prefilled editor has no entry to open.
    ///
    /// The formatting happens here rather than at the call site because
    /// `Money.formattedForEditing()` is internal to this module, and keeping it that way is
    /// what stops an app-target view growing money formatting of its own.
    public func prefill(code: ReliefCode, amount: Money) {
        selectedCode = code
        amountText = amount.formattedForEditing()
    }

    public func load() async {
        availableDependents = ((try? await store.dependentDrafts()) ?? [])
            .map { DependentOption(id: $0.id, name: $0.name) }

        if let ruleSet = context.ruleSet {
            admittedClaimantsByCode = Self.admittedClaimantsByCode(ruleSet)
        }

        if let result = context.result {
            // Automatic reliefs are excluded. The evaluator grants them in full from
            // household facts and discards any logged amount without a trace, so an
            // entry against one is a figure that silently goes nowhere.
            availableCodes = result.allAssessments
                .filter { !Self.isAutomatic($0.code, in: context) }
                .map { assessment in
                    ReliefOption(code: assessment.code,
                                 name: assessment.name,
                                 admittedClaimants: admittedClaimantsByCode[assessment.code] ?? [])
                }
                .sorted { $0.name < $1.name }
        }

        guard let editingID,
              let existing = try? await store.entryDrafts(forYear: context.year)
                  .first(where: { $0.id == editingID }) else { return }

        selectedCode = existing.code
        amountText = existing.amount.formattedForEditing()
        originalAmount = existing.amount
        vendor = existing.vendor
        spentOn = existing.spentOn
        claimant = existing.claimant
        dependentID = existing.dependentID
        note = existing.note
    }

    /// Why this form cannot be saved as it stands, or `nil`.
    ///
    /// Computed over the *currently selected* code, never captured at `load()`: the user
    /// can switch an entry that opened against an automatic relief onto a manual one,
    /// and a sticky flag would leave that form permanently unsaveable while citing a
    /// code it no longer holds.
    public var readOnlyReason: String? {
        guard let selectedCode, Self.isAutomatic(selectedCode, in: context) else { return nil }
        return "\(reliefName(selectedCode)) is granted automatically from your household details. Any amount recorded here is ignored — edit your details instead."
    }

    public var isReadOnly: Bool { readOnlyReason != nil }

    /// Whether this editor opened against an existing entry rather than a blank form —
    /// drives the title ("Edit entry" vs. "New entry") and whether Delete can show at all.
    public var isEditing: Bool { editingID != nil }

    /// Delete only ever makes sense for an entry that already exists, and never for one
    /// this same editor has already deleted (that state is `deletedID`, not `editingID`,
    /// and it is already handled by `canSave`) — but showing Delete on a read-only
    /// automatic relief would offer to delete a row the evaluator ignores anyway.
    public var canDelete: Bool { editingID != nil && !isReadOnly }

    /// Claimants the selected relief admits, from the rulebook via
    /// `admittedClaimantsByCode` — not from `availableCodes`. Empty means no restriction.
    public var admittedClaimants: [Claimant] {
        guard let selectedCode else { return [] }
        return admittedClaimantsByCode[selectedCode] ?? []
    }

    /// Whether naming a dependent is meaningful for this relief. Never required — no
    /// offerable relief has a per-dependent cap, so the engine ignores `dependentID`.
    ///
    /// True either when the rule admits a child, parent or grandparent claimant, or when
    /// its own eligibility turns on some fact about a dependent even with no claimant
    /// restriction of its own — CHILDCARE and BREASTFEEDING are exactly this shape.
    public var allowsDependent: Bool {
        // Naming a person is only meaningful once the claim is *for* one. LIFESTYLE
        // admits self, spouse and child, so the rule below is satisfied — but with
        // "Claimed for" left at Self, "Which person" was a row asking which of the
        // user's children this receipt of their own belonged to.
        //
        // Not folded into the rule check: a relief whose own eligibility turns on a
        // dependent fact — CHILDCARE, BREASTFEEDING — is about a dependant however the
        // claim is attributed, and those keep the row.
        let admitted = admittedClaimants
        let claimantAdmitsADependent = !admitted.isEmpty
            && !Set(admitted).isDisjoint(with: [.child, .parent, .grandparent])
            && [.child, .parent, .grandparent].contains(claimant)
        let ownRuleTurnsOnADependentFact = selectedCode
            .flatMap { context.rule(for: $0) }
            .map { Self.mentionsDependentFact($0.eligibility) } ?? false
        return claimantAdmitsADependent || ownRuleTurnsOnADependentFact
    }

    /// What the chosen relief's cap does to the amount being typed.
    ///
    /// The editor has never mentioned a cap. Someone entering RM 3,000 against a relief
    /// capped at RM 2,500 got a clean save and no hint that RM 500 of it counts for
    /// nothing — they would find out by opening the relief afterwards and noticing that
    /// "claimed" and "allowed" disagree, if they noticed at all.
    ///
    /// A warning, never a refusal. LHDN caps what it allows; it does not stop anyone
    /// spending more, and an editor that rejected the real figure would push the user to
    /// write down a number that is not what they spent.
    public struct CapGuidance: Hashable, Sendable {
        public var cap: Money
        /// Already claimed against this relief, excluding the entry being edited.
        public var claimedElsewhere: Money
        /// Room left before this entry is counted.
        public var headroom: Money
        /// How much of this entry would exceed the cap. Zero when it fits.
        public var overBy: Money
    }

    public var capGuidance: CapGuidance? {
        guard let selectedCode,
              let assessment = context.result?.allAssessments
                  .first(where: { $0.code == selectedCode }),
              assessment.cap > .zero else { return nil }

        // The evaluation counts the entry being edited, so its current amount has to come
        // back out — otherwise re-opening a RM 1,700 entry and retyping the same figure
        // reports it as RM 1,700 over.
        let claimedElsewhere = assessment.claimed - originalAmount
        let headroom = claimedElsewhere >= assessment.cap
            ? .zero
            : assessment.cap - claimedElsewhere
        let amount = MoneyParsing.money(from: amountText) ?? .zero
        let overBy = amount > headroom ? amount - headroom : .zero

        return CapGuidance(cap: assessment.cap,
                           claimedElsewhere: claimedElsewhere,
                           headroom: headroom,
                           overBy: overBy)
    }

    /// The relief as the user knows it, for a message the user reads.
    ///
    /// These two sentences named the rulebook's key — "SELF_AND_DEPENDENTS is granted
    /// automatically…" — which is the leak `ReliefCopy` exists to prevent. The rulebook's
    /// own name is the fallback, and the raw code only if neither is known.
    private func reliefName(_ code: ReliefCode) -> String {
        let full = availableCodes.first { $0.code == code }?.name
            ?? context.result?.allAssessments.first { $0.code == code }?.name
            ?? code.rawValue
        return ReliefCopy.shortName(for: code, fullName: full)
    }

    public var validationError: String? {
        guard let selectedCode else { return "Choose a relief." }
        if Self.isAutomatic(selectedCode, in: context) {
            // The evaluator grants this in full from household facts and discards any
            // logged amount without a trace. `selectedCode` is a plain settable
            // property and `availableCodes` already excludes automatic codes, so a
            // check that only consulted the picker's list would silently vanish the
            // moment a caller sets this directly rather than through the picker.
            return "\(reliefName(selectedCode)) is granted automatically from your household details and cannot be logged here."
        }
        guard let amount = MoneyParsing.money(from: amountText) else {
            return amountText.isEmpty ? "Enter an amount." : "That is not an amount."
        }
        if amount <= .zero { return "The amount must be more than RM 0.00." }
        let admitted = admittedClaimants
        if !admitted.isEmpty && !admitted.contains(claimant) {
            // PARENTS_MEDICAL admits only .parent and .grandparent. Left at the default
            // .individual it is refused by the engine, and the user loses the claim with
            // no explanation. Refusing here, with a reason, is the whole point. This
            // also protects PARENTS_CHECKUP, a sub-limit with no claimant predicate of
            // its own: `admittedClaimants` inherits [.parent, .grandparent] from
            // PARENTS_MEDICAL, its parent, so the same guard reaches it.
            return "Choose who this claim is for."
        }
        return nil
    }

    public var canSave: Bool {
        // `TaxStore.save` clears `deletedAt`, so a save after a delete silently revives
        // the row the user just deleted. The editor is where that is decided, not the
        // view: a rule left to the view is a rule `swift test` cannot see, and every
        // platform's view would have to remember it independently. `undoDelete()` clears
        // `deletedID`, so undo restores the ability to save along with the entry.
        deletedID == nil && !isReadOnly && validationError == nil
    }

    /// Spec §6.5: same-session duplicates are caught by a prompt at entry time, before
    /// the reconciliation sweep ever has to deal with them.
    ///
    /// Warns rather than blocks. Two identical receipts from the same shop on the same
    /// day are unusual but real, and refusing the second would make the app wrong about
    /// the user's own money. The sweep only ever merges rows that arrived from different
    /// devices; a duplicate the user confirms here is theirs to keep.
    public private(set) var duplicateWarning: String?

    public func checkForDuplicate() async {
        duplicateWarning = nil
        guard let code = selectedCode,
              let amount = MoneyParsing.money(from: amountText) else { return }

        // Matches what `save()` actually persists: `dependentID` goes through
        // unconditionally now (see `save()`), so the candidate key must too, or a real
        // duplicate against an entry that carries a dependent would go undetected.
        let candidate = DedupeKey.entry(year: context.year,
                                        code: code,
                                        amountSen: amount.sen,
                                        day: Normalisation.day(spentOn),
                                        vendor: Normalisation.vendor(vendor),
                                        claimant: claimant,
                                        dependentID: dependentID)
        let existing = (try? await store.entryDrafts(forYear: context.year)) ?? []
        for entry in existing where entry.id != editingID {
            guard let key = try? await store.dedupeKey(forEntry: entry.id), key == candidate else { continue }
            duplicateWarning = "You already logged \(amount.formatted()) for this. Save anyway?"
            return
        }
    }

    @discardableResult
    public func save() async -> Bool {
        guard canSave,
              let code = selectedCode,
              let amount = MoneyParsing.money(from: amountText) else { return false }

        let draft = EntryDraft(id: editingID ?? UUID(),
                               year: context.year,
                               code: code,
                               amount: amount,
                               claimant: claimant,
                               // Always the current value, never forced to nil here.
                               // Nilling it out at save time erased which child a
                               // CHILDCARE or BREASTFEEDING claim was for the moment the
                               // user reopened and saved a synced entry — no tax impact
                               // (the engine ignores `dependentID` on a fixed cap), but
                               // a silent loss of the user's own record in the two
                               // reliefs where naming a child is the entire point.
                               //
                               // A dependent the selected relief cannot display is
                               // already gone by now: `selectedCode`'s setter clears it
                               // when the code changes to one with no dependent field,
                               // which is the only moment the two can disagree.
                               dependentID: dependentID,
                               vendor: vendor.trimmingCharacters(in: .whitespaces),
                               spentOn: spentOn,
                               note: note)

        do {
            _ = try await store.save(draft)
        } catch {
            return false
        }
        // Without this the Home headline keeps its old value until something else
        // reloads, and the user watches their entry vanish into nothing.
        await context.reload()
        return true
    }

    public func delete() async {
        guard let editingID else { return }
        try? await store.softDeleteEntry(id: editingID)
        deletedID = editingID
        await context.reload()
    }

    public func undoDelete() async {
        guard let deletedID else { return }
        try? await store.restoreEntry(id: deletedID)
        self.deletedID = nil
        await context.reload()
    }

    /// Walks a single predicate tree for the claimants it admits directly — no
    /// inheritance. The closed predicate language makes this a total function over the
    /// tree rather than a guess.
    static func ownClaimants(_ predicate: EligibilityPredicate?) -> [Claimant] {
        guard let predicate else { return [] }

        func walk(_ node: EligibilityPredicate) -> [Claimant] {
            switch node {
            case .claimant(let admitted): return admitted
            case .all(let children), .any(let children): return children.flatMap(walk)
            case .not(let inner): return walk(inner)
            default: return []
            }
        }
        // Order preserved from the rulebook so the picker is stable between launches.
        var seen: Set<Claimant> = []
        return walk(predicate).filter { seen.insert($0).inserted }
    }

    /// Every code's admitted claimants, inherited from the nearest ancestor that
    /// declares one.
    ///
    /// A sub-limit is claimed under its parent's ceiling, and therefore under its
    /// parent's conditions — PARENTS_CHECKUP has no `.claimant(in:)` of its own; the
    /// restriction to parent and grandparent lives on PARENTS_MEDICAL, its parent.
    /// `RuleSet.relief(for:)` carries no parent link, so this walks the tree once,
    /// threading the nearest declared claimant set down to every descendant that
    /// doesn't declare its own, and remembers the answer for every code.
    static func admittedClaimantsByCode(_ ruleSet: RuleSet) -> [ReliefCode: [Claimant]] {
        var map: [ReliefCode: [Claimant]] = [:]

        func walk(_ rule: ReliefRule, inherited: [Claimant]) {
            let own = ownClaimants(rule.eligibility)
            let effective = own.isEmpty ? inherited : own
            map[rule.code] = effective
            for child in rule.children { walk(child, inherited: effective) }
        }
        for rule in ruleSet.reliefs { walk(rule, inherited: []) }
        return map
    }

    /// True when a predicate turns on some fact about a dependent — age, education or
    /// disability — even where it declares no claimant restriction at all. CHILDCARE
    /// and BREASTFEEDING are exactly this shape: eligible on a fact about a child, with
    /// no `.claimant(in:)` node anywhere in the tree.
    static func mentionsDependentFact(_ predicate: EligibilityPredicate?) -> Bool {
        guard let predicate else { return false }

        func walk(_ node: EligibilityPredicate) -> Bool {
            switch node {
            case .dependentAge, .dependentEducation, .dependentIsDisabled: return true
            case .all(let children), .any(let children): return children.contains(where: walk)
            case .not(let inner): return walk(inner)
            default: return false
            }
        }
        return walk(predicate)
    }

    static func isAutomatic(_ code: ReliefCode, in context: YearContext) -> Bool {
        context.rule(for: code)?.automatic ?? false
    }
}

extension EntryEditorViewModel: Identifiable {
    /// `.sheet(item:)` needs `Identifiable`; there is no natural stable id before the
    /// first save (a new entry has no `editingID`), so identity is the view model
    /// instance itself, which is exactly the lifetime `.sheet(item:)` cares about.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}

extension Money {
    /// Plain digits for a text field. `formatted()` is for display — putting `RM 1,820.50`
    /// into an editable field means the user has to delete the prefix to type.
    func formattedForEditing() -> String {
        let sign = sen < 0 ? "-" : ""
        let magnitude = abs(sen)
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", magnitude % 100))"
    }
}
