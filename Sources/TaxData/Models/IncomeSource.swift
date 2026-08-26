import Foundation
import SwiftData
import TaxKit

/// What kind of income a source pays, which decides what Relio is allowed to claim about
/// it. It does NOT imply statutory deductions and does not gate any arithmetic — see
/// `deductsEPF`. Spec §4.
public enum IncomeKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// A job. Aggregates into chargeable income on Form BE.
    case employment
    /// Part-time or occasional work — ITA 1967 §4(f) "other gains or profits".
    /// Declared on Form BE under other gains and profits, so it aggregates too.
    case occasional
    /// Carried on as a business, in practice registered with SSM. Belongs on Form B,
    /// where expenses are deductible. Relio's figure is not the figure you file.
    case business
    /// Rental. Expenses are deductible, so pooling gross rent overstates.
    case rental
    /// Anything else, including a value from a future build this one cannot read.
    case other
}

/// One stream of income — a job, a side gig — with its own history.
///
/// Deliberately global rather than hanging off `TaxYear`: a salary set in April 2024 is
/// still in force in January 2025. Per-year sources would force the user to re-enter an
/// unchanged salary every January, which is the problem this design exists to remove.
@Model
public final class IncomeSource {

    public var id: UUID = UUID()
    public var name: String = ""
    public var kindRaw: String = IncomeKind.employment.rawValue

    /// `nil` means "not asked yet", which the UI turns into a prompt. `false` would mean
    /// "confirmed no deductions" — a different claim, and one nobody made. Spec §7.
    public var deductsEPF: Bool?
    public var deductsSOCSO: Bool?

    /// The last day this source paid, inclusive. The only thing that can stop a recurring
    /// rate — leaving a job has no record of its own.
    public var endedOn: Date?

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \IncomeRecord.source)
    public var records: [IncomeRecord]?

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

extension IncomeSource {

    /// An unreadable raw value reads as `.other`, which is the kind that warns rather than
    /// the kind that stays silent — the safe direction for income Relio may not model.
    public var kind: IncomeKind {
        get { IncomeKind(rawValue: kindRaw) ?? .other }
        set { kindRaw = newValue.rawValue }
    }

    public var liveRecords: [IncomeRecord] {
        (records ?? []).filter { $0.deletedAt == nil }
    }

    public var isLive: Bool { deletedAt == nil }
}
