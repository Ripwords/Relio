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
    @State private var sourcePendingDeletion: IncomeSourceRow?
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
                    ForEach(source.records) { record in
                        Button {
                            editing = IncomeRecordEditorViewModel(mode: .edit(record))
                        } label: { recordRow(record) }
                            .buttonStyle(.plain)
                            .swipeActions {
                                Button("Delete", role: .destructive) {
                                    Task { await model.deleteRecord(id: record.id) }
                                }
                            }
                    }
                    Button("Add a change") {
                        // Anchored to the year on screen, not to today: see
                        // `IncomeViewModel.newRecordDate`.
                        editing = IncomeRecordEditorViewModel(mode: .addRecord(sourceID: source.id),
                                                              today: model.newRecordDate)
                    }
                    .font(.subheadline)
                    // A row, not a swipe on the header: list headers do not take swipe
                    // actions, and there is no way to rename a source, so removing one
                    // is the only remedy for a name typed wrong. It has to be reachable.
                    //
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
                    MoneyText(amount: model.derivedTotal, weight: .medium)
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
                Text(model.isOverridden
                     ? "Relio is using your own figure. Your EA form is the one that counts."
                     : "Relio adds up your records. If your EA form says something different, enter it above.")
            }

            if let overrideError {
                Section {
                    Text(overrideError).foregroundStyle(.orange).font(.footnote)
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
                Task { await model.deleteSource(id: source.id) }
                sourcePendingDeletion = nil
            }
            Button("Keep it", role: .cancel) { sourcePendingDeletion = nil }
        } message: { source in
            // Names what goes with it. The records are the derivation — losing them
            // silently is losing the user's working, and there is no undo for this.
            Text(Self.deletionWarning(recordCount: source.records.count))
        }
        .task {
            await model.refresh()
            overrideText = model.overrideEditingText
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
                MoneyText(amount: source.total, font: .subheadline, weight: .semibold)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(source.name)
                MoneyText(amount: source.total, font: .subheadline, weight: .semibold)
            }
        }
    }

    private func recordRow(_ record: IncomeRecordDraft) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                recordDate(record)
                Spacer()
                MoneyText(amount: record.amount, font: .subheadline)
            }
            VStack(alignment: .leading, spacing: 2) {
                recordDate(record)
                MoneyText(amount: record.amount, font: .subheadline)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(record))
    }

    private func recordDate(_ record: IncomeRecordDraft) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.effectiveFrom, format: .dateTime.day().month(.abbreviated).year())
            Text(record.shape == .recurring ? "a month" : "one-off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func accessibilityLabel(_ record: IncomeRecordDraft) -> String {
        let date = record.effectiveFrom.formatted(.dateTime.day().month(.wide).year())
        return record.shape == .recurring
            ? "From \(date), \(record.amount.formatted()) a month"
            : "\(date), \(record.amount.formatted()) received"
    }
}
