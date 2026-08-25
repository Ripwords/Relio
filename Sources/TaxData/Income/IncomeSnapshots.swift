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
