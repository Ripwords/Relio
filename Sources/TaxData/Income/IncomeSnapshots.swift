import Foundation
import TaxKit

/// One record, as a value. The derivation works on these rather than on `@Model` objects,
/// so every boundary case is testable without a container, an actor or a clock.
public struct IncomeRecordSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var shape: IncomeShape
    /// A monthly rate for `.recurring`; the amount received for `.oneOff`.
    public var amount: Money
    public var effectiveFrom: Date

    public init(id: UUID = UUID(), shape: IncomeShape = .recurring,
                amount: Money = .zero, effectiveFrom: Date = .distantPast) {
        self.id = id
        self.shape = shape
        self.amount = amount
        self.effectiveFrom = effectiveFrom
    }
}

public struct IncomeSourceSnapshot: Hashable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var kind: IncomeKind
    /// The last day this source paid, inclusive.
    public var endedOn: Date?
    public var records: [IncomeRecordSnapshot]

    public init(id: UUID = UUID(), name: String = "", kind: IncomeKind = .employment,
                endedOn: Date? = nil, records: [IncomeRecordSnapshot] = []) {
        self.id = id
        self.name = name
        self.kind = kind
        self.endedOn = endedOn
        self.records = records
    }
}

/// What one source contributed to a year — what the Income screen shows per source.
public struct IncomeSourceTotal: Hashable, Sendable, Identifiable {
    public var sourceID: UUID
    public var name: String
    public var kind: IncomeKind
    public var total: Money

    public var id: UUID { sourceID }
}

/// One source as the Income screen shows it: the source itself, what it contributed to the
/// year, and the records the contribution is built from.
///
/// The source travels as a whole `IncomeSourceDraft` rather than as the name and kind the
/// list happens to display. An edit round-trips this draft back through
/// `TaxStore.save(_: IncomeSourceDraft)`, which overwrites every field it carries — so a
/// partial draft would silently null `deductsEPF`/`deductsSOCSO`, turning "confirmed no
/// EPF" back into "not asked" without anyone touching them.
public struct IncomeYearRow: Hashable, Sendable, Identifiable {
    public var source: IncomeSourceDraft
    public var total: Money
    public var records: [IncomeRecordDraft]

    public var id: UUID { source.id }

    public init(source: IncomeSourceDraft, total: Money = .zero,
                records: [IncomeRecordDraft] = []) {
        self.source = source
        self.total = total
        self.records = records
    }
}

/// A year's income, answered in one read.
public struct IncomeYearSummary: Hashable, Sendable {
    public var rows: [IncomeYearRow]

    /// The year's gross, or `nil` when nothing in the timeline reaches into it — see
    /// `IncomeDerivation.knownAnnualGross`. `nil` is "we have not been told", which is a
    /// different claim from RM 0.00, and the screen must not render the second when it
    /// means the first.
    public var knownTotal: Money?

    public init(rows: [IncomeYearRow] = [], knownTotal: Money? = nil) {
        self.rows = rows
        self.knownTotal = knownTotal
    }
}
