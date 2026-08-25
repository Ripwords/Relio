import Foundation
import Observation
import TaxKit
import TaxData

/// The state behind the income editor sheet.
///
/// It lives here rather than in the view for two reasons: `Money.formattedForEditing()` is
/// internal to this module, so an app-target view cannot call it; and an editor that
/// validates in the view puts a decision about the user's money where `swift test` cannot
/// reach it.
@MainActor
@Observable
public final class IncomeRecordEditorViewModel {

    public enum Mode: Hashable, Sendable {
        case addSource
        case addRecord(sourceID: UUID)
        case edit(IncomeRecordDraft)
    }

    public let mode: Mode
    public var name: String = ""
    public var kind: IncomeKind = .employment
    public var shape: IncomeShape = .recurring
    public var amountText: String = ""
    public var effectiveFrom: Date

    public init(mode: Mode, today: Date = Date()) {
        self.mode = mode
        self.effectiveFrom = today
        if case .edit(let record) = mode {
            shape = record.shape
            amountText = record.amount.formattedForEditing()
            effectiveFrom = record.effectiveFrom
        }
    }

    public var isSourceMode: Bool {
        if case .addSource = mode { return true }
        return false
    }

    public var validationError: String? {
        if isSourceMode {
            return name.trimmingCharacters(in: .whitespaces).isEmpty ? "Give this a name." : nil
        }
        guard let amount = MoneyParsing.money(from: amountText) else {
            return amountText.isEmpty ? "Enter an amount." : "That is not an amount."
        }
        return amount > .zero ? nil : "The amount must be more than RM 0.00."
    }

    public var canSave: Bool { validationError == nil }

    public func sourceDraft() -> IncomeSourceDraft? {
        guard isSourceMode, canSave else { return nil }
        var draft = IncomeSourceDraft(name: name.trimmingCharacters(in: .whitespaces))
        draft.kind = kind
        return draft
    }

    /// For `.edit`, keeps the record's id so the store updates in place rather than
    /// inserting a second row.
    public func recordDraft() -> IncomeRecordDraft? {
        guard !isSourceMode, canSave,
              let amount = MoneyParsing.money(from: amountText) else { return nil }

        var draft: IncomeRecordDraft
        switch mode {
        case .addRecord(let sourceID):
            draft = IncomeRecordDraft(sourceID: sourceID)
        case .edit(let record):
            draft = record
        case .addSource:
            return nil
        }
        draft.shape = shape
        draft.amount = amount
        draft.effectiveFrom = effectiveFrom
        return draft
    }

    public static func label(for kind: IncomeKind) -> String {
        switch kind {
        case .employment: "A job"
        case .occasional: "Part-time or occasional work"
        case .business:   "A registered business"
        case .rental:     "Rental"
        case .other:      "Something else"
        }
    }

    /// Says what Relio can and cannot do with each kind at the moment the user picks it,
    /// which is earlier and more useful than a warning after the fact.
    public static func footnote(for kind: IncomeKind) -> String {
        switch kind {
        case .employment:
            "Counted in full. Relio handles this."
        case .occasional:
            "Occasional work is declared on Form BE under other gains and profits. Relio handles this."
        case .business:
            "A registered business is filed on Form B, where expenses are deductible. Relio counts this income in full, so its estimate will be higher than what you file."
        case .rental:
            "Rental expenses are deductible. Relio counts the full amount, so its estimate will be higher than what you file."
        case .other:
            "Counted in full. Check how this income is treated before relying on the estimate."
        }
    }
}

extension IncomeRecordEditorViewModel: Identifiable {
    /// `.sheet(item:)` needs `Identifiable`, and there is no natural stable id here: an
    /// `.addSource` or `.addRecord` editor has nothing saved yet, and two `.edit`
    /// editors for the same record are still two separate pieces of typing. Identity is
    /// the view model instance itself, which is exactly the lifetime `.sheet(item:)`
    /// cares about — the same choice `EntryEditorViewModel` makes.
    public nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }
}
