import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The income timeline, shown as its derivation rather than as a single figure.
///
/// Each source lists the records it is built from with their dates, its own subtotal, and
/// then the year's derived total; the user's own figure sits beneath, saying which of the
/// two is actually in play. Spec §10 — a user who cannot see why Relio thinks they earned
/// what it says cannot tell whether it is right, and this number drives every tax figure
/// in the app.
struct IncomeView: View {

    @Bindable var model: IncomeViewModel

    /// Held here, never built inside `.sheet(item:)`: a view model constructed in a
    /// presentation closure is replaced by a fresh, empty one on every re-render, which
    /// discards whatever the user had typed. This is the defect the Plan 2 view-layer
    /// review found.
    @State private var editing: IncomeRecordEditorViewModel?
    @State private var overrideText = ""
    /// Set when a write of the user's own figure did not happen. Same construction as the
    /// editor sheet's `saveError` — an orange `.footnote` section — because it is the same
    /// kind of news: a save the user believes happened and did not.
    @State private var overrideError: String?
    /// The source a destructive tap is asking about, held until it is confirmed.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sourcePendingDeletion: IncomeSourceRow?
    /// Set when a delete reported failure. Shown the same way as `overrideError` — the row
    /// staying put is exactly what a tap that never registered looks like, and there is no
    /// undo for income to fall back on.
    @State private var deleteError: String?
    @FocusState private var overrideFieldFocused: Bool

    var body: some View {
        List {
            if model.sources.isEmpty {
                // A row rather than an `.overlay`: the override field below is exactly
                // what a user with no timeline needs, and an overlay would cover it.
                Section {
                    ContentUnavailableView("No income recorded",
                                           systemImage: "banknote",
                                           description: Text("Add your salary and Relio will work out the year's total, including any raises."))
                }
            }

            ForEach(model.sources) { source in
                Section {
                    ForEach(source.timeline) { entry in
                        Button {
                            editing = IncomeRecordEditorViewModel(
                                mode: .edit(entry.draft),
                                today: entry.draft.effectiveFrom,
                                // A record never collides with itself.
                                occupiedDays: model.occupiedDays(forSource: source.id,
                                                                 excluding: entry.id))
                        } label: { recordRow(entry) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task {
                                        deleteError = nil
                                        let deleted = await model.deleteRecord(id: entry.id)
                                        if !deleted {
                                            deleteError = "Relio could not remove that record. It is still here — try again."
                                        }
                                    }
                                }
                            }
                    }
                    // "Add a change" named the mechanism and not the thing. A raise is the
                    // reason almost anyone opens this screen twice, and the timeline
                    // feature exists for it — the label should say so.
                    Button("Add a raise, bonus or change") {
                        // The day after this source's latest record, clamped into the year
                        // on screen — never today, and never a date that ties with a rate
                        // already there. See `IncomeViewModel.newRecordDate(forSource:)`.
                        editing = IncomeRecordEditorViewModel(
                            mode: .addRecord(sourceID: source.id),
                            today: model.newRecordDate(forSource: source.id),
                            occupiedDays: model.occupiedDays(forSource: source.id))
                    }
                    .font(.subheadline)
                    // A row, not a swipe on the header: list headers do not take swipe
                    // actions. This is where a job that has ended gets its end date, which
                    // is the only thing that can stop a recurring rate — without it, a
                    // salary the user left behind keeps being paid for every future year.
                    Button(source.endedOn == nil ? "Edit this source" : "Edit or reopen this source") {
                        editing = IncomeRecordEditorViewModel(
                            mode: .editSource(source.draft),
                            today: model.newRecordDate(forSource: source.id))
                    }
                    .font(.subheadline)
                    // Confirmed, unlike the per-record swipe: this destroys the source and
                    // every record under it, there is no undo, and it sits one row under
                    // the entirely benign "Add a change".
                    Button("Delete this source", role: .destructive) {
                        sourcePendingDeletion = source
                    }
                    .font(.subheadline)
                } header: {
                    sourceHeader(source)
                } footer: {
                    // Joined in the view model, where the kind is known — not matched back
                    // up here by name.
                    if let warning = source.warning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section {
                LabeledContent("From your records") {
                    // `nil` is "the timeline says nothing about this year", which is not
                    // RM 0.00. Rendering zero here would state, in the app's most
                    // confident voice, that the household earned nothing in a year they
                    // simply have not told Relio about.
                    if let derived = model.derivedTotal {
                        MoneyText(amount: derived, weight: .medium)
                    } else {
                        Text("Not recorded")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
                LabeledContent("Your own figure") {
                    TextField("Optional", text: $overrideText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                        .focused($overrideFieldFocused)
                }
                if model.isOverridden {
                    Button("Use my records instead") {
                        overrideFieldFocused = false
                        // The field is emptied *after* the write reports back, never
                        // before. Clearing first and never reconciling leaves an empty
                        // field under a footer saying Relio is using the user's own
                        // figure whenever the write fails — the exact contradiction the
                        // field is populated to avoid.
                        Task { await clearOverride() }
                    }
                }
            } header: {
                Text("Gross income for YA \(String(model.context.year))")
            } footer: {
                Text(Self.incomeFooter(isOverridden: model.isOverridden,
                                       isYearKnown: model.isYearKnown,
                                       year: model.context.year))
            }

            if let overrideError {
                Section {
                    Text(overrideError).foregroundStyle(.orange).font(.footnote)
                }
            }

            if let deleteError {
                Section {
                    Text(deleteError).foregroundStyle(.orange).font(.footnote)
                }
            }
        }
        .navigationTitle("Income")
        // Inline, like every other bar in the app. A large title over this list draws
        // straight on top of the first source's header.
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    editing = IncomeRecordEditorViewModel(mode: .addSource,
                                                          today: model.newRecordDate)
                } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add an income source")
            }
            // A decimal pad has no return key, so `.onSubmit` never fires on this field.
            // Without a way to say "done", a typed override would be lost every time.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { overrideFieldFocused = false }
            }
        }
        .sheet(item: $editing) { editor in
            IncomeRecordEditor(editor: editor, model: model)
        }
        // An alert, not a `confirmationDialog`. On this OS a confirmation dialog is drawn
        // as a narrow popover anchored to its source; at the largest Dynamic Type sizes
        // that popover is about two words wide, and it clipped both the message and the
        // destructive button itself — a confirmation whose button you cannot read is not a
        // confirmation. The alert is full width, keeps both buttons legible, and scrolls
        // its message. Verified by render at AX5 both ways.
        .alert("Delete this source?",
               isPresented: Binding(get: { sourcePendingDeletion != nil },
                                    set: { if !$0 { sourcePendingDeletion = nil } }),
               presenting: sourcePendingDeletion) { source in
            Button("Delete \(source.name)", role: .destructive) {
                Task {
                    deleteError = nil
                    let deleted = await model.deleteSource(id: source.id)
                    if !deleted {
                        deleteError = "Relio could not remove \(source.name). It is still here — try again."
                    }
                }
                sourcePendingDeletion = nil
            }
            Button("Keep it", role: .cancel) { sourcePendingDeletion = nil }
        } message: { source in
            // Names what goes with it. The records are the derivation, and losing them
            // silently is losing the user's working. The undo toast below is the second
            // net; the confirmation stays because restoring a source is a worse
            // experience than not deleting it.
            Text(Self.deletionWarning(recordCount: source.records.count))
        }
        // Spec §11.6: every destructive action is undoable, on every platform. Income was
        // the exception — both deletes already soft-deleted, so the rows were recoverable
        // the whole time and nothing could ask for them back. The per-record swipe was the
        // sharper edge of the two: no confirmation and no undo, on a gesture people fire
        // by accident, against the figure every tax number in the app derives from.
        .overlay(alignment: .bottom) {
            if let undoable = model.lastDeleted {
                UndoToast(message: undoable.message,
                          undo: { await model.undoDelete() },
                          isPresented: Binding(get: { model.lastDeleted != nil },
                                               set: { if !$0 { model.clearUndo() } }))
                    .padding(.bottom, 12)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: model.lastDeleted)
        .task {
            await model.refresh()
            overrideText = model.overrideEditingText
            #if DEBUG
            // The editor is presented from this view's own state, so RootView's route
            // switch cannot reach it. Its four modes are four different screens.
            switch DemoHarness.screen {
            case "income-add-source":
                editing = IncomeRecordEditorViewModel(mode: .addSource,
                                                      today: model.newRecordDate)
            case "income-add-change":
                if let source = model.sources.first {
                    editing = IncomeRecordEditorViewModel(
                        mode: .addRecord(sourceID: source.id),
                        today: model.newRecordDate(forSource: source.id),
                        occupiedDays: model.occupiedDays(forSource: source.id))
                }
            case "income-edit-record":
                if let source = model.sources.first, let record = source.records.first {
                    editing = IncomeRecordEditorViewModel(
                        mode: .edit(record),
                        today: record.effectiveFrom,
                        occupiedDays: model.occupiedDays(forSource: source.id,
                                                         excluding: record.id))
                }
            default: break
            }
            #endif
        }
        // Leaving the field is the commit. The user can also get here from the keyboard's
        // Done button, which resigns focus.
        .onChange(of: overrideFieldFocused) { _, isFocused in
            guard !isFocused else { return }
            Task { await commitOverride() }
        }
    }

    /// Saves whatever is in the field, or puts the saved figure back if it is not an
    /// amount — `MoneyParsing` returns `nil` for both "" and "abc", and treating the
    /// second as "clear my override" would throw away a figure the user never touched.
    ///
    /// The write's result is checked. Dropping it means a failed save looks identical to
    /// a successful one except that the field snaps back to the old figure, which reads
    /// as the app having eaten the user's typing — and every tax number in the app then
    /// goes on quoting the stale figure with nothing said.
    private func commitOverride() async {
        let typed = overrideText.trimmingCharacters(in: .whitespaces)
        let parsed = MoneyParsing.money(from: typed)
        guard typed.isEmpty || parsed != nil else {
            overrideText = model.overrideEditingText
            return
        }
        guard parsed != model.override else { return }
        overrideError = nil
        let saved = await model.saveOverride(parsed)
        overrideText = model.overrideEditingText
        if !saved {
            overrideError = "Relio could not save your own figure. It is unchanged — try again."
        }
    }

    /// Same discipline for going back to the records: the field follows what is actually
    /// persisted, and a clear that did not happen says so.
    private func clearOverride() async {
        overrideError = nil
        let cleared = await model.clearOverride()
        overrideText = model.overrideEditingText
        if !cleared {
            overrideError = "Relio could not go back to your records. Your own figure is still in use — try again."
        }
    }

    /// Says which figure is in force, and says nothing confident about a year Relio has
    /// no records for. "Relio adds up your records" under a RM 0.00 is a claim about the
    /// user's earnings; "you have not recorded anything" is a description of the app.
    private static func incomeFooter(isOverridden: Bool, isYearKnown: Bool,
                                     year: Int) -> String {
        if isOverridden {
            return "Relio is using your own figure. Your EA form is the one that counts."
        }
        if !isYearKnown {
            return "Nothing you have recorded reaches YA \(String(year)), so Relio has no figure for it. Add a record dated in that year, or enter your own figure above."
        }
        return "Relio adds up your records. If your EA form says something different, enter it above."
    }

    /// Plain counting, spelled out rather than inflected: this sentence is the last thing
    /// a user reads before losing the records for good. Kept to four lines at AX5, which
    /// is what an alert shows before it starts scrolling — the source's own name is
    /// already on the destructive button, so it is not repeated here.
    private static func deletionWarning(recordCount count: Int) -> String {
        guard count > 0 else { return "This cannot be undone." }
        let records = count == 1 ? "1 record" : "\(count) records"
        return "Removes \(records) too. Cannot be undone."
    }

    /// `ViewThatFits` rather than a bare `HStack`: at the largest Dynamic Type sizes the
    /// name and the subtotal cannot share a line, and the loser would be truncated. A
    /// truncated amount on the screen that explains the amounts is a defect.
    private func sourceHeader(_ source: IncomeSourceRow) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                Text(source.name)
                Spacer()
                sourceSubtotal(source)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                sourceSubtotal(source)
            }
        }
    }

    /// Held to the same standard as the year's total beneath it. When nothing in the
    /// timeline reaches the year on screen, no source contributed to it either — and a
    /// per-source RM 0.00 makes the same false claim in smaller type, once per row.
    @ViewBuilder
    private func sourceSubtotal(_ source: IncomeSourceRow) -> some View {
        if model.isYearKnown {
            MoneyText(amount: source.total, font: .subheadline, weight: .semibold)
        } else {
            Text("Not recorded").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func recordRow(_ entry: IncomeTimelineEntry) -> some View {
        let record = entry.draft
        return ViewThatFits(in: .horizontal) {
            HStack {
                recordDate(entry)
                Spacer()
                recordAmount(entry)
            }
            VStack(alignment: .leading, spacing: 2) {
                recordDate(entry)
                recordAmount(entry)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(entry))
    }

    /// The figure, with the unit that qualifies it.
    ///
    /// "a month" belongs beside the amount rather than after the change's name, where it
    /// ran the two together as "Starting rate a month".
    private func recordAmount(_ entry: IncomeTimelineEntry) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            MoneyText(amount: entry.draft.amount, font: Theme.figure(17, .semibold))
            if entry.draft.shape == .recurring {
                Text("a month")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The date, what happened on it, and by how much.
    ///
    /// "1 Apr 2025 / a month" left the reader comparing two figures to work out that the
    /// second was a raise. Naming it is what turns a list of dated amounts into the
    /// history the timeline was built to be.
    private func recordDate(_ entry: IncomeTimelineEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.draft.effectiveFrom,
                 format: .dateTime.day().month(.abbreviated).year())
            HStack(spacing: 4) {
                Text(entry.change.title)
                if let delta = entry.change.delta {
                    // A lower rate reads "−", not "+RM 2,000" under a heading that
                    // already says the rate went down.
                    Text("\(entry.change.isIncrease ? "+" : "−")\(delta.formatted())")
                        .monospacedDigit()
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// The same history the row shows, said in full.
    private func accessibilityLabel(_ entry: IncomeTimelineEntry) -> String {
        let record = entry.draft
        let date = record.effectiveFrom.formatted(.dateTime.day().month(.wide).year())
        guard record.shape == .recurring else {
            return "\(date), one-off payment of \(record.amount.formatted()) received"
        }
        let base = "From \(date), \(record.amount.formatted()) a month"
        guard let delta = entry.change.delta else {
            return "\(base), \(entry.change.title.lowercased())"
        }
        return "\(base), \(entry.change.title.lowercased()) of "
             + "\(delta.formatted()) a month"
    }
}
