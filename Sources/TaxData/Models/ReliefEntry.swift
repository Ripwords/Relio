import Foundation
import SwiftData
import TaxKit

/// One logged claim: an amount against a relief code, in one Year of Assessment.
///
/// Refers to its rule by `ReliefCode` and never by relationship. The rulebook is bundled
/// JSON, not database rows, so when YA2026 renames or splits a category these rows do not
/// migrate — the engine resolves the code against whichever ruleset applies. Spec §5
/// calls this the most important decoupling in the design.
@Model
public final class ReliefEntry {

    public var id: UUID = UUID()
    public var reliefCodeRaw: String = ""
    public var amountSen: Int = 0
    public var claimantRaw: String = Claimant.individual.rawValue

    /// Which dependent this is claimed for, by identity rather than by relationship.
    /// A dangling id is a recoverable data issue; a broken object graph is not.
    public var dependentID: UUID?

    /// The entry's own vendor and date. See the deviation note in the plan: the dedupe
    /// key needs both, and a hand-typed entry has no `Document` to borrow them from.
    public var vendor: String = ""
    public var spentOn: Date?
    public var note: String = ""

    /// SHA-256 over the normalised identifying tuple. Written only by `TaxStore`.
    public var dedupeKey: String = ""

    /// Cached answer to "is this claim missing a document the rulebook requires".
    /// Denormalised because `#Predicate` cannot call the engine, and the Documents tab
    /// filters on it. Recomputed by `TaxStore` on every write to this entry.
    public var needsDocument: Bool = false

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    /// Set by the reconciliation sweep when this row lost to a duplicate, so the merge
    /// is auditable and reversible rather than a silent disappearance.
    public var mergedInto: UUID?

    public var taxYear: TaxYear?

    @Relationship(inverse: \Document.entries)
    public var documents: [Document]?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension ReliefEntry {

    public var reliefCode: ReliefCode {
        get { ReliefCode(reliefCodeRaw) }
        set { reliefCodeRaw = newValue.rawValue }
    }

    public var amount: Money {
        get { Money(sen: amountSen) }
        set { amountSen = newValue.sen }
    }

    /// An unrecognised claimant falls back to the taxpayer rather than trapping: one bad
    /// row synced from a newer build must not take the whole list down.
    public var claimant: Claimant {
        get { Claimant(rawValue: claimantRaw) ?? .individual }
        set { claimantRaw = newValue.rawValue }
    }

    public var documentKinds: Set<DocumentKind> {
        Set((documents ?? []).filter(\.isLive).map(\.kind))
    }

    public var isLive: Bool { deletedAt == nil }
}
