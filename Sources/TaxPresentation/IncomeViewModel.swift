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

    public func saveOverride(_ amount: Money?) async {
        guard var facts = try? await store.yearFacts(for: context.year) else { return }
        facts.grossIncomeOverride = amount
        try? await store.saveYearFacts(facts, for: context.year)
        await reloadEverything()
    }

    public func clearOverride() async {
        await saveOverride(nil)
    }

    @discardableResult
    public func addSource(_ draft: IncomeSourceDraft) async -> UUID {
        let id = (try? await store.save(draft)) ?? draft.id
        await reloadEverything()
        return id
    }

    public func addRecord(_ draft: IncomeRecordDraft) async {
        _ = try? await store.save(draft)
        await reloadEverything()
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
