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

    public var selectedCode: ReliefCode?
    public var amountText: String = ""
    public var vendor: String = ""
    public var spentOn: Date?
    public var claimant: Claimant = .individual
    public var dependentID: UUID?
    public var note: String = ""

    public private(set) var availableCodes: [ReliefOption] = []
    public private(set) var availableDependents: [DependentOption] = []
    public private(set) var isReadOnly = false
    public private(set) var readOnlyReason: String?

    private let context: YearContext
    private let store: TaxStore
    private let editingID: UUID?
    private var deletedID: UUID?

    public init(context: YearContext, store: TaxStore, editing id: UUID?) {
        self.context = context
        self.store = store
        self.editingID = id
    }

    public func load() async {
        availableDependents = ((try? await store.dependentDrafts()) ?? [])
            .map { DependentOption(id: $0.id, name: $0.name) }

        if let result = context.result {
            // Automatic reliefs are excluded. The evaluator grants them in full from
            // household facts and discards any logged amount without a trace, so an
            // entry against one is a figure that silently goes nowhere.
            availableCodes = result.allAssessments
                .filter { !Self.isAutomatic($0.code, in: context) }
                .map { assessment in
                    ReliefOption(code: assessment.code,
                                 name: assessment.name,
                                 admittedClaimants: Self.admittedClaimants(
                                     context.rule(for: assessment.code)))
                }
                .sorted { $0.name < $1.name }
        }

        guard let editingID,
              let existing = try? await store.entryDrafts(forYear: context.year)
                  .first(where: { $0.id == editingID }) else { return }

        selectedCode = existing.code
        amountText = existing.amount.formattedForEditing()
        vendor = existing.vendor
        spentOn = existing.spentOn
        claimant = existing.claimant
        dependentID = existing.dependentID
        note = existing.note

        if Self.isAutomatic(existing.code, in: context) {
            isReadOnly = true
            readOnlyReason = "\(existing.code.rawValue) is granted automatically from your household details. Any amount recorded here is ignored — edit your details instead."
        }
    }

    /// Claimants the selected relief admits. Empty means no restriction.
    public var admittedClaimants: [Claimant] {
        guard let selectedCode else { return [] }
        return availableCodes.first { $0.code == selectedCode }?.admittedClaimants ?? []
    }

    /// Whether naming a dependent is meaningful for this relief. Never required — no
    /// offerable relief has a per-dependent cap, so the engine ignores `dependentID`.
    public var allowsDependent: Bool {
        !admittedClaimants.isEmpty
            && !Set(admittedClaimants).isDisjoint(with: [.child, .parent, .grandparent])
    }

    public var validationError: String? {
        if selectedCode == nil { return "Choose a relief." }
        guard let amount = MoneyParsing.money(from: amountText) else {
            return amountText.isEmpty ? "Enter an amount." : "That is not an amount."
        }
        if amount <= .zero { return "The amount must be more than RM 0.00." }
        let admitted = admittedClaimants
        if !admitted.isEmpty && !admitted.contains(claimant) {
            // PARENTS_MEDICAL admits only .parent and .grandparent. Left at the default
            // .individual it is refused by the engine, and the user loses the claim with
            // no explanation. Refusing here, with a reason, is the whole point.
            return "Choose who this claim is for."
        }
        return nil
    }

    public var canSave: Bool {
        !isReadOnly && validationError == nil
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

        let candidateDependentID = allowsDependent ? dependentID : nil
        let candidate = DedupeKey.entry(year: context.year,
                                        code: code,
                                        amountSen: amount.sen,
                                        day: Normalisation.day(spentOn),
                                        vendor: Normalisation.vendor(vendor),
                                        claimant: claimant,
                                        dependentID: candidateDependentID)
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
                               dependentID: allowsDependent ? dependentID : nil,
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

    /// Walks a rule's eligibility predicate for the claimants it admits.
    ///
    /// The rulebook is the authority on who a relief may be claimed for, and the closed
    /// predicate language makes this a total function over the tree rather than a guess.
    static func admittedClaimants(_ rule: ReliefRule?) -> [Claimant] {
        guard let predicate = rule?.eligibility else { return [] }

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

    static func isAutomatic(_ code: ReliefCode, in context: YearContext) -> Bool {
        context.rule(for: code)?.automatic ?? false
    }
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
