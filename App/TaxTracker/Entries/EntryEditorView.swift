import SwiftUI
import TaxKit
import TaxPresentation

/// How the editor is on screen.
///
/// The sheet arrives with no navigation bar of its own, so it has to bring one. The
/// pushed copy is already inside the stack it was pushed onto; wrapping there nests a
/// stack in a stack and renders two bars, and puts a "Cancel" button next to the back
/// button that already does the same job.
enum EntryEditorPresentation: Hashable {
    case sheet
    case pushed
}

struct EntryEditorView: View {

    /// `@State`, not a stored `let`. The pushed copy is rebuilt every time the view that
    /// declared the destination re-renders; the sheet copy is rebuilt every time the
    /// presenter re-renders. Either way a stored model would be silently replaced
    /// mid-edit by an empty one, discarding whatever the user had typed.
    @State private var model: EntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    let presentation: EntryEditorPresentation
    /// Home copies out of the shared evaluation rather than reading it through, so it has
    /// to be told a write happened. The delete path has always said so; the save path
    /// used to rely on Home being destroyed and rebuilt, which is the defect this wave
    /// removes.
    let onSaved: () -> Void
    let onDeleted: (EntryEditorViewModel) -> Void

    @State private var hasDate = false

    init(model: EntryEditorViewModel,
         presentation: EntryEditorPresentation,
         onSaved: @escaping () -> Void,
         onDeleted: @escaping (EntryEditorViewModel) -> Void) {
        _model = State(initialValue: model)
        self.presentation = presentation
        self.onSaved = onSaved
        self.onDeleted = onDeleted
    }

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .sheet:
            NavigationStack { form }
        case .pushed:
            form
        }
    }

    private var form: some View {
        @Bindable var model = model
        return Form {
            if let reason = model.readOnlyReason {
                Section {
                    Label(reason, systemImage: "info.circle")
                        .font(.footnote)
                }
            }

            Section {
                Picker("Relief", selection: $model.selectedCode) {
                    Text("Choose…").tag(ReliefCode?.none)
                    ForEach(model.availableCodes) { option in
                        Text(option.name).tag(ReliefCode?.some(option.code))
                    }
                }

                LabeledContent("Amount") {
                    TextField("0.00", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }

                if !model.admittedClaimants.isEmpty {
                    Picker("Claimed for", selection: $model.claimant) {
                        ForEach(model.admittedClaimants, id: \.self) { who in
                            Text(who.rawValue.capitalized).tag(who)
                        }
                    }
                }

                if model.allowsDependent, !model.availableDependents.isEmpty {
                    Picker("Which person", selection: $model.dependentID) {
                        Text("Not specified").tag(UUID?.none)
                        ForEach(model.availableDependents) { dependent in
                            Text(dependent.name).tag(UUID?.some(dependent.id))
                        }
                    }
                }
            }

            Section {
                TextField("Vendor", text: $model.vendor)
                Toggle("Has a date", isOn: $hasDate)
                if hasDate {
                    DatePicker("Spent on",
                               selection: Binding(get: { model.spentOn ?? Date() },
                                                  set: { model.spentOn = $0 }),
                               displayedComponents: .date)
                }
                TextField("Note", text: $model.note, axis: .vertical)
            }

            if let error = model.validationError, !model.amountText.isEmpty {
                Section { Text(error).foregroundStyle(.orange).font(.footnote) }
            } else if let warning = model.duplicateWarning {
                Section {
                    Label(warning, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            if model.readOnlyReason == nil, model.canDelete {
                Section {
                    Button("Delete", role: .destructive) {
                        Task {
                            await model.delete()
                            onDeleted(model)
                            dismiss()
                        }
                    }
                }
            }
        }
            .navigationTitle(model.isEditing ? "Edit entry" : "New entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The pushed copy already has a back button doing exactly this; only the
                // sheet, which has no way out otherwise, needs its own.
                if presentation == .sheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            if await model.save() {
                                onSaved()
                                dismiss()
                            }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task {
                await model.load()
                hasDate = model.spentOn != nil
            }
            .onChange(of: hasDate) { _, isOn in
                if !isOn { model.spentOn = nil }
            }
            // Spec §6.5: catch the duplicate at entry time, before the sweep has to.
            // Every field that composes the dedupe key must re-check — leaving one out
            // (claimant, dependent, date) lets an edit to just that field silently drop
            // or miss a warning that still applies.
            .onChange(of: model.amountText) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.vendor) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.selectedCode) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.claimant) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.dependentID) { Task { await model.checkForDuplicate() } }
            .onChange(of: model.spentOn) { Task { await model.checkForDuplicate() } }
    }
}
