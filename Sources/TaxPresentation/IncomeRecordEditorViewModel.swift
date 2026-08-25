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
        /// An existing source, carried whole so `sourceDraft()` can hand every field back
        /// — including the id, so the store updates in place instead of inserting a
        /// second row, and `deductsEPF`/`deductsSOCSO`, which this sheet never shows and
        /// must not quietly reset to "not asked".
        case editSource(IncomeSourceDraft)
        case addRecord(sourceID: UUID)
        case edit(IncomeRecordDraft)
    }

    public let mode: Mode
    public var name: String = ""
    public var kind: IncomeKind = .employment
    public var shape: IncomeShape = .recurring
    public var amountText: String = ""
    public var effectiveFrom: Date

    /// Whether this source has stopped paying. A toggle plus a date, the same shape
    /// onboarding uses for "started part way through the year", because "no end date" has
    /// to stay representable: a bare `DatePicker` always holds *some* date, so a user
    /// could set an end date and never clear it again.
    public var hasEndDate: Bool = false
    public var endedOn: Date

    /// Days this source already has a record on, so a new one can say when it ties with
    /// an existing rate. Empty is simply "nothing to warn about".
    public var occupiedDays: [Date] = []

    /// `today` has no default on purpose. Both live call sites anchor it to the year on
    /// screen; a `Date()` fallback would let a future one silently regress to the device's
    /// date, which for the usual case — the newest rulebook being last year — pre-fills a
    /// date outside the year being edited.
    public init(mode: Mode, today: Date, occupiedDays: [Date] = []) {
        self.mode = mode
        self.effectiveFrom = today
        self.endedOn = today
        self.occupiedDays = occupiedDays
        switch mode {
        case .addSource:
            break
        case .editSource(let source):
            name = source.name
            kind = source.kind
            hasEndDate = source.endedOn != nil
            endedOn = source.endedOn ?? today
        case .addRecord:
            break
        case .edit(let record):
            shape = record.shape
            amountText = record.amount.formattedForEditing()
            effectiveFrom = record.effectiveFrom
        }
    }

    public var isSourceMode: Bool {
        switch mode {
        case .addSource, .editSource: true
        case .addRecord, .edit: false
        }
    }

    public var isEditingSource: Bool {
        if case .editSource = mode { return true }
        return false
    }

    /// A note, not an error: two records on one day is legal and the derivation resolves it
    /// the same way every time. It is just never what someone meant, and nothing on the
    /// list distinguishes the rate that wins from the one contributing nothing.
    public var dateCollisionNote: String? {
        guard !isSourceMode else { return nil }
        guard occupiedDays.contains(where: { IncomeCalendar.isSameDay($0, effectiveFrom) })
        else { return nil }
        return "This source already has a record on that date. Only one of the two will count — pick a different day unless you meant to replace it."
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

    /// For `.editSource`, keeps the source's id — and every field this sheet does not
    /// show — so the store updates in place rather than inserting a second row.
    public func sourceDraft() -> IncomeSourceDraft? {
        guard isSourceMode, canSave else { return nil }

        var draft: IncomeSourceDraft
        if case .editSource(let existing) = mode {
            draft = existing
        } else {
            draft = IncomeSourceDraft()
        }
        draft.name = name.trimmingCharacters(in: .whitespaces)
        draft.kind = kind
        // Normalised to the start of the day: `endedOn` is compared against day
        // boundaries in the derivation, and the picker hands back whatever time of day it
        // happened to be carrying.
        draft.endedOn = hasEndDate ? IncomeCalendar.startOfDay(endedOn) : nil
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
        case .addSource, .editSource:
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
