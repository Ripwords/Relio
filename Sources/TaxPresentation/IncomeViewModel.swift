import Foundation
import Observation
import TaxKit
import TaxData

public struct IncomeSourceRow: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    public var total: Money
    public var records: [IncomeRecordDraft]
    /// True for income Relio does not model correctly — see `IncomeViewModel`.
    public var needsScopeWarning: Bool
}

/// The Income screen's state.
///
/// Shows the derivation, not just its result: a user who cannot see why Relio thinks they
/// earned what it says cannot tell whether it is right, and this figure drives every tax
/// number in the app. Spec §10.
@MainActor
@Observable
public final class IncomeViewModel {

    public let context: YearContext
    public private(set) var sources: [IncomeSourceRow] = []
    public private(set) var derivedTotal: Money = .zero
    public private(set) var override: Money?
    public private(set) var outOfScopeWarnings: [String] = []

    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    public var isOverridden: Bool { override != nil }

    /// The figure that actually reaches the engine.
    public var effectiveTotal: Money { override ?? derivedTotal }

    /// The override as the user would type it, for the screen's text field.
    ///
    /// `Money.formattedForEditing()` is internal to this module, so an app-target view
    /// cannot produce this itself — and a field left blank while the footer beneath it
    /// says Relio is using the user's own figure tells them two contradictory things at
    /// once. It is also what the view puts back when someone types something that is not
    /// an amount, rather than silently clearing a figure they never asked to clear.
    public var overrideEditingText: String { override?.formattedForEditing() ?? "" }

    public func refresh() async {
        let year = context.year
        let totals = (try? await store.incomeTotals(for: year)) ?? []
        let drafts = (try? await store.incomeSourceDrafts()) ?? []

        var rows: [IncomeSourceRow] = []
        for total in totals {
            guard let draft = drafts.first(where: { $0.id == total.sourceID }) else { continue }
            let records = (try? await store.incomeRecordDrafts(forSource: total.sourceID)) ?? []
            rows.append(IncomeSourceRow(id: total.sourceID, name: total.name, kind: total.kind,
                                        total: total.total, records: records,
                                        needsScopeWarning: Self.isOutOfScope(draft.kind)))
        }
        sources = rows
        derivedTotal = totals.reduce(Money.zero) { $0 + $1.total }
        override = (try? await store.yearFacts(for: year))?.grossIncomeOverride
        outOfScopeWarnings = rows.filter(\.needsScopeWarning).map(Self.warning(for:))
    }

    /// Business and rental income only. Occasional work is ITA 1967 §4(f) and is declared
    /// on Form BE, so flagging it would make the warning noise the user learns to ignore.
    static func isOutOfScope(_ kind: IncomeKind) -> Bool {
        kind == .business || kind == .rental
    }

    static func warning(for row: IncomeSourceRow) -> String {
        switch row.kind {
        case .business:
            return "\(row.name) looks like business income. Relio estimates Form BE figures; business income belongs on Form B, where expenses are deductible."
        case .rental:
            return "\(row.name) is rental income. Relio counts it in full, but rental expenses are deductible, so your real chargeable income is lower."
        default:
            return ""
        }
    }

    // MARK: - Writes

    /// `false` on failure. A swallowed failure here is the worst kind for this screen:
    /// the user types a corrected figure, believes it saved, and every tax number in the
    /// app keeps quoting the stale one with no signal anything went wrong.
    @discardableResult
    public func saveOverride(_ amount: Money?) async -> Bool {
        var succeeded = false
        do {
            var facts = try await store.yearFacts(for: context.year)
            facts.grossIncomeOverride = amount
            try await store.saveYearFacts(facts, for: context.year)
            succeeded = true
        } catch {
            succeeded = false
        }
        // Either way, so the screen reflects what is actually persisted rather than
        // what the caller hoped to write.
        await reloadEverything()
        return succeeded
    }

    @discardableResult
    public func clearOverride() async -> Bool {
        await saveOverride(nil)
    }

    /// `nil` on failure — never a fabricated id. `TaxStore.save(_ draft:
    /// IncomeSourceDraft)` returns `draft.id` on success, so falling back to `draft.id`
    /// on failure would return the identical value either way: the caller could not
    /// tell a write that actually happened from one that silently didn't.
    @discardableResult
    public func addSource(_ draft: IncomeSourceDraft) async -> UUID? {
        var id: UUID?
        do {
            id = try await store.save(draft)
        } catch {
            id = nil
        }
        await reloadEverything()
        return id
    }

    /// `false` on failure, including `IncomeStoreError.unknownIncomeSource` — a record
    /// saved against a source that does not exist. Swallowing that would let the user
    /// add income, see no error, and have the entry silently vanish from every read.
    @discardableResult
    public func addRecord(_ draft: IncomeRecordDraft) async -> Bool {
        var succeeded = false
        do {
            _ = try await store.save(draft)
            succeeded = true
        } catch {
            succeeded = false
        }
        await reloadEverything()
        return succeeded
    }

    public func deleteSource(id: UUID) async {
        try? await store.softDeleteIncomeSource(id: id)
        await reloadEverything()
    }

    public func deleteRecord(id: UUID) async {
        try? await store.softDeleteIncomeRecord(id: id)
        await reloadEverything()
    }

    /// Income changes chargeable income, so every tax figure in the app moves with it.
    /// Reloading the shared evaluation is not optional here.
    private func reloadEverything() async {
        await context.reload()
        await refresh()
    }
}
