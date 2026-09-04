import Foundation
import Observation
import TaxKit
import TaxData

public struct IncomeSourceRow: Hashable, Sendable, Identifiable {
    /// The source itself, kept whole so the edit sheet can round-trip it back to the
    /// store without dropping the fields this screen never shows — `deductsEPF` and
    /// `deductsSOCSO`, where `nil` means "not asked" and losing a `true` is losing an
    /// answer the user gave.
    public var draft: IncomeSourceDraft
    public var total: Money
    public var records: [IncomeRecordDraft]

    /// The records read as a history rather than as a list of dated amounts.
    ///
    /// Two rows saying "1 Jan, RM 10,000 a month" and "1 Apr, RM 11,500 a month" *are* a
    /// raise, and nothing on the screen said so — the reader had to compare the two
    /// figures and work out what had happened. Naming each entry is what makes the
    /// timeline legible as the thing it is.
    public var timeline: [IncomeTimelineEntry] { IncomeTimelineEntry.build(from: records) }

    public var id: UUID { draft.id }
    public var name: String { draft.name }
    public var kind: IncomeKind { draft.kind }
    /// The last day this source paid, inclusive. `nil` is a source still paying.
    public var endedOn: Date? { draft.endedOn }

    /// True for income Relio does not model correctly — see `IncomeViewModel`.
    public var needsScopeWarning: Bool
    /// The compliance notice for this source, or `nil` when there is nothing to say.
    ///
    /// It is joined to its source here, where the kind is known, rather than handed to the
    /// view as a loose list to match up by name. Two sources whose names are substrings of
    /// one another — "Rental" and "Rental Penang" — would otherwise attach each other's
    /// notice, and a data join has no business in a view.
    public var warning: String?
}

/// The Income screen's state.
///
/// Shows the derivation, not just its result: a user who cannot see why Relio thinks they
/// earned what it says cannot tell whether it is right, and this figure drives every tax
/// number in the app. Spec §10.
/// One dated point in a source's history, with what it did.
public struct IncomeTimelineEntry: Hashable, Sendable, Identifiable {

    public enum Change: Hashable, Sendable {
        /// The first rate on record. Nothing to compare it against.
        case opening
        /// A rate that replaced a lower one — a raise, by this much a month.
        case raise(by: Money)
        /// A rate that replaced a higher one.
        case cut(by: Money)
        /// A rate that replaced one of the same amount. Unusual but recordable, and it
        /// must not be labelled a raise of RM 0.00.
        case unchanged
        /// A single payment — a bonus, a freelance invoice, a commission.
        case oneOff

        public var title: String {
            switch self {
            case .opening: "Starting rate"
            case .raise: "Raise"
            case .cut: "Lower rate"
            case .unchanged: "Rate restated"
            case .oneOff: "One-off payment"
            }
        }

        /// Whether the step went up. Only meaningful where `delta` is non-nil.
        public var isIncrease: Bool {
            if case .raise = self { return true }
            return false
        }

        /// The size of the step, for the entries where a step is what happened.
        public var delta: Money? {
            switch self {
            case .raise(let by), .cut(let by): by
            case .opening, .unchanged, .oneOff: nil
            }
        }
    }

    public var draft: IncomeRecordDraft
    public var change: Change

    public var id: UUID { draft.id }

    /// Walks the records in date order and labels each one against the recurring rate in
    /// force before it.
    ///
    /// One-off payments do not participate: a bonus in March does not make April's salary
    /// a cut, which is what comparing every record against the one before it would say.
    static func build(from records: [IncomeRecordDraft]) -> [IncomeTimelineEntry] {
        let ordered = records.sorted {
            ($0.effectiveFrom, $0.id.uuidString) < ($1.effectiveFrom, $1.id.uuidString)
        }
        var previousRate: Money?
        return ordered.map { record in
            guard record.shape == .recurring else {
                return IncomeTimelineEntry(draft: record, change: .oneOff)
            }
            defer { previousRate = record.amount }
            guard let previous = previousRate else {
                return IncomeTimelineEntry(draft: record, change: .opening)
            }
            if record.amount > previous {
                return IncomeTimelineEntry(draft: record,
                                           change: .raise(by: record.amount - previous))
            }
            if record.amount < previous {
                return IncomeTimelineEntry(draft: record,
                                           change: .cut(by: previous - record.amount))
            }
            return IncomeTimelineEntry(draft: record, change: .unchanged)
        }
    }
}

@MainActor
@Observable
public final class IncomeViewModel {

    public let context: YearContext
    public private(set) var sources: [IncomeSourceRow] = []

    /// What the records add up to for the viewed year, or `nil` when the timeline says
    /// nothing about that year at all.
    ///
    /// `nil` is not zero. With a 2025-only timeline, switching the year menu to YA2024
    /// must not put "From your records RM 0.00" on screen under a footer saying Relio
    /// added the records up: the user recorded nothing for 2024 and Relio knows nothing
    /// about it. This is the same `knownAnnualGross` the projection hands the engine —
    /// taken from the same read — so the screen and Home cannot disagree.
    public private(set) var derivedTotal: Money?
    public private(set) var override: Money?

    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    public var isOverridden: Bool { override != nil }

    /// True when the timeline says something about the viewed year — including that
    /// nothing was earned, which is an answer. False means nobody has told Relio yet.
    public var isYearKnown: Bool { derivedTotal != nil }

    // There is deliberately no `effectiveTotal` here. `override ?? derived` is the rule
    // that decides what reaches the engine, and it lives in `TaxStore.project(year:)`,
    // which is the only place that gets to apply it. A second copy on this screen had no
    // production caller and had already drifted: it read a missing year as RM 0.00 while
    // the projection read it as unknown.

    /// The override as the user would type it, for the screen's text field.
    ///
    /// `Money.formattedForEditing()` is internal to this module, so an app-target view
    /// cannot produce this itself — and a field left blank while the footer beneath it
    /// says Relio is using the user's own figure tells them two contradictory things at
    /// once. It is also what the view puts back when someone types something that is not
    /// an amount, rather than silently clearing a figure they never asked to clear.
    public var overrideEditingText: String { override?.formattedForEditing() ?? "" }

    /// The date a newly-added record should start out on when the source has no records
    /// yet — the first day of the year being viewed, not today.
    ///
    /// The newest shipped rulebook is normally the previous assessment year, so `Date()`
    /// pre-fills a date *outside* the year on screen: the record is then written, listed
    /// under a year-scoped subtotal it contributes nothing to, and the arithmetic visibly
    /// does not close. Onboarding anchors its salary date the same way, and for the same
    /// reason.
    public var newRecordDate: Date { IncomeCalendar.startOfYear(context.year) }

    /// The date a new record for `sourceID` should start out on: the day after that
    /// source's latest existing record, clamped into the year being viewed.
    ///
    /// Not the year's first day. Onboarding writes its rate dated exactly 1 January, so a
    /// year-start default meant "Add a change" → type an amount → Save produced *two*
    /// rates on the same day. The derivation breaks that tie on `id.uuidString`: the same
    /// way on every device, but arbitrary with respect to what the user meant — a coin
    /// flip over whether the year uses the old rate or the new one, with both rows
    /// rendering identically and nothing saying one contributes nothing. The tie-break
    /// stays; this stops the screen steering people into the tie.
    public func newRecordDate(forSource sourceID: UUID) -> Date {
        let yearStart = IncomeCalendar.startOfYear(context.year)
        guard let latest = sources.first(where: { $0.id == sourceID })?
            .records.map(\.effectiveFrom).max() else { return yearStart }

        // Clamped both ways: a record carried in from an earlier year must not pre-fill a
        // date outside the year on screen, and a record on 31 December must not push the
        // default into the next one.
        return min(max(IncomeCalendar.dayAfter(latest), yearStart),
                   IncomeCalendar.endOfYear(context.year))
    }

    /// The days `sourceID` already has a record on, so the editor can warn about a tie.
    /// `excluding` keeps a record being edited from colliding with itself.
    public func occupiedDays(forSource sourceID: UUID, excluding recordID: UUID? = nil) -> [Date] {
        (sources.first { $0.id == sourceID }?.records ?? [])
            .filter { $0.id != recordID }
            .map { IncomeCalendar.startOfDay($0.effectiveFrom) }
    }

    /// One store call, not three. Taking the subtotals, the sources and their records
    /// separately let a concurrent soft-delete land between two reads and drop a row from
    /// `sources` while its amount still counted toward `derivedTotal` — a derivation that
    /// visibly does not add up. `incomeSummary(for:)` answers all of it from one fetch.
    public func refresh() async {
        let year = context.year
        let summary = (try? await store.incomeSummary(for: year)) ?? IncomeYearSummary()

        sources = summary.rows.map { row in
            let needsWarning = Self.isOutOfScope(row.source.kind)
            return IncomeSourceRow(draft: row.source, total: row.total, records: row.records,
                                   needsScopeWarning: needsWarning,
                                   // Joined here, where the kind is already in hand.
                                   warning: needsWarning
                                       ? Self.warning(name: row.source.name,
                                                      kind: row.source.kind)
                                       : nil)
        }
        derivedTotal = summary.knownTotal
        override = (try? await store.yearFacts(for: year))?.grossIncomeOverride
    }

    /// Business and rental income only. Occasional work is ITA 1967 §4(f) and is declared
    /// on Form BE, so flagging it would make the warning noise the user learns to ignore.
    static func isOutOfScope(_ kind: IncomeKind) -> Bool {
        kind == .business || kind == .rental
    }

    static func warning(name: String, kind: IncomeKind) -> String? {
        switch kind {
        case .business:
            return "\(name) looks like business income. Relio estimates Form BE figures; business income belongs on Form B, where expenses are deductible."
        case .rental:
            return "\(name) is rental income. Relio counts it in full, but rental expenses are deductible, so your real chargeable income is lower."
        default:
            return nil
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

    /// Saves an edited source — a rename, a change of kind, or the end date that is the
    /// only thing able to stop a recurring rate.
    ///
    /// The same store call as `addSource`, which updates in place when the draft keeps its
    /// id. Reported the same way too: an end date the user set and Relio did not save
    /// leaves the old job's salary running forever, over-stating every future year's
    /// income by an entire salary, with the derivation on screen looking perfectly
    /// reasonable.
    @discardableResult
    public func saveSource(_ draft: IncomeSourceDraft) async -> Bool {
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

    /// `false` on failure, like every other write here. A delete that silently did not
    /// happen looks identical to one that did — the row stays, and the user reads that as
    /// the tap not registering and tries again. There is no undo for income, and the
    /// per-record swipe has no confirmation to fall back on either.
    /// What the last delete removed, so the toast can put it back.
    ///
    /// Spec §11.6 asks for soft delete plus an undo toast on every destructive action.
    /// Income was the exception — both deletes soft-delete, so the rows were always
    /// recoverable, and nothing could ask for them back.
    public enum Undoable: Hashable, Sendable {
        case source(UUID, name: String)
        case record(UUID)

        public var message: String {
            switch self {
            case .source(_, let name): "Deleted \(name)"
            case .record: "Deleted income change"
            }
        }
    }

    public private(set) var lastDeleted: Undoable?

    public func clearUndo() { lastDeleted = nil }

    /// Puts back whatever the last delete removed. Idempotent at the store level, so a
    /// double tap on the toast cannot do harm.
    public func undoDelete() async {
        guard let lastDeleted else { return }
        do {
            switch lastDeleted {
            case .source(let id, _): try await store.restoreIncomeSource(id: id)
            case .record(let id): try await store.restoreIncomeRecord(id: id)
            }
        } catch {
            // Nothing to say that the screen cannot already show: the reload below puts
            // the true state back on screen either way, and a failed undo leaves the row
            // deleted, which is what the user is already looking at.
        }
        self.lastDeleted = nil
        await reloadEverything()
    }

    @discardableResult
    public func deleteSource(id: UUID) async -> Bool {
        var succeeded = false
        // Captured before the delete: afterwards the source is gone from the drafts and
        // the toast would have no name to show.
        let name = sources.first { $0.id == id }?.name ?? "income source"
        do {
            try await store.softDeleteIncomeSource(id: id)
            lastDeleted = .source(id, name: name)
            succeeded = true
        } catch {
            succeeded = false
        }
        await reloadEverything()
        return succeeded
    }

    @discardableResult
    public func deleteRecord(id: UUID) async -> Bool {
        var succeeded = false
        do {
            try await store.softDeleteIncomeRecord(id: id)
            lastDeleted = .record(id)
            succeeded = true
        } catch {
            succeeded = false
        }
        await reloadEverything()
        return succeeded
    }

    /// Income changes chargeable income, so every tax figure in the app moves with it.
    /// Reloading the shared evaluation is not optional here.
    private func reloadEverything() async {
        await context.reload()
        await refresh()
    }
}
