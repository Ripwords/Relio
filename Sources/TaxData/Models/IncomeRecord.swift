import Foundation
import SwiftData
import TaxKit

public enum IncomeShape: String, Codable, Hashable, Sendable, CaseIterable {
    /// A monthly rate, in force from `effectiveFrom` until something replaces or ends it.
    case recurring
    /// A single amount received on `effectiveFrom` — a bonus, a freelance invoice.
    case oneOff
}

/// One point in a source's history.
///
/// `effectiveFrom` means different things by shape, deliberately: for `recurring` it is the
/// date the rate takes effect, for `oneOff` it is the date the money arrived. One dated
/// field with a documented meaning per shape beats two of which one is always nil.
@Model
public final class IncomeRecord {

    public var id: UUID = UUID()
    public var shapeRaw: String = IncomeShape.recurring.rawValue
    /// A monthly rate for `recurring`; the amount received for `oneOff`.
    public var amountSen: Int = 0
    public var effectiveFrom: Date = Date.distantPast
    public var note: String = ""

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public var source: IncomeSource?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension IncomeRecord {

    public var shape: IncomeShape {
        get { IncomeShape(rawValue: shapeRaw) ?? .recurring }
        set { shapeRaw = newValue.rawValue }
    }

    public var amount: Money {
        get { Money(sen: amountSen) }
        set { amountSen = newValue.sen }
    }

    public var isLive: Bool { deletedAt == nil }
}
