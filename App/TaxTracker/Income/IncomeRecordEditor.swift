import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// Bindings only. Every decision on this sheet — what counts as valid, what a draft looks
/// like, what each income kind means — lives in `IncomeRecordEditorViewModel`, where
/// `swift test` can reach it.
struct IncomeRecordEditor: View {

    @Bindable var editor: IncomeRecordEditorViewModel
    let model: IncomeViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var saveError: String?

    var body: some View {
        NavigationStack {
            Form {
                if editor.isSourceMode {
                    Section {
                        TextField("Name", text: $editor.name)
                        // Inline, not the default menu: a menu picker shows its
                        // selection on one line and truncates it — "Part-time or
                        // occasional work" becomes "Part-ti…work" at the largest
                        // Dynamic Type sizes, which is the choice the user most needs
                        // to read.
                        Picker("Kind", selection: $editor.kind) {
                            ForEach(IncomeKind.allCases, id: \.self) { kind in
                                Text(IncomeRecordEditorViewModel.label(for: kind)).tag(kind)
                            }
                        }
                        .pickerStyle(.inline)
                    } footer: {
                        Text(IncomeRecordEditorViewModel.footnote(for: editor.kind))
                    }
                } else {
                    Section {
                        // Inline for the same reason as the kind picker above: the menu
                        // style rendered this as "A mo…ly rate" at AX5.
                        Picker("This is", selection: $editor.shape) {
                            Text("A monthly rate").tag(IncomeShape.recurring)
                            Text("A one-off payment").tag(IncomeShape.oneOff)
                        }
                        .pickerStyle(.inline)
                        LabeledContent(editor.shape == .recurring ? "Amount a month" : "Amount") {
                            TextField("0.00", text: $editor.amountText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        DatePicker(editor.shape == .recurring ? "From" : "Received on",
                                   selection: $editor.effectiveFrom, displayedComponents: .date)
                    } footer: {
                        Text(editor.shape == .recurring
                             ? "Relio pays this rate from that date until you change it. A change part-way through a month is split by days."
                             : "Counted in the year it was received.")
                    }

                    if let error = editor.validationError, !editor.amountText.isEmpty {
                        Section { Text(error).foregroundStyle(.orange).font(.footnote) }
                    }
                }

                if let saveError {
                    Section {
                        Text(saveError).foregroundStyle(.orange).font(.footnote)
                    }
                }
            }
            .navigationTitle(editor.isSourceMode ? "New source" : "Change")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .disabled(!editor.canSave)
                }
            }
        }
    }

    /// Dismisses only on a write that actually happened. Dismissing regardless would throw
    /// away everything the user typed and leave them looking at a screen that does not
    /// show what they just entered, with nothing said about why.
    private func save() async {
        saveError = nil
        if let source = editor.sourceDraft() {
            guard await model.addSource(source) != nil else {
                saveError = "Relio could not save this source. Nothing was lost — try again."
                return
            }
        } else if let record = editor.recordDraft() {
            // `.edit` keeps the record's id, so this updates in place.
            guard await model.addRecord(record) else {
                saveError = "Relio could not save this change. Nothing was lost — try again."
                return
            }
        }
        dismiss()
    }
}
