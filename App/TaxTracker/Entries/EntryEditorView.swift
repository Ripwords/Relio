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
    /// A button plus `navigationDestination(isPresented:)` rather than a NavigationLink,
    /// so a screenshot run can open the picker — there is no way to tap this simulator.
    @State private var isPickingRelief = false

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
                // A searchable list rather than a `Picker`. Two dozen reliefs with no way
                // to search is a lot of scrolling on the screen the app exists to make
                // quick, and a picker row can only show a name — which is not enough to
                // decide between "Lifestyle" and "Lifestyle — sports".
                Button {
                    isPickingRelief = true
                } label: {
                    LabeledContent("Relief") {
                        if let code = model.selectedCode {
                            Text(ReliefCopy.shortName(
                                for: code,
                                fullName: model.availableCodes
                                    .first { $0.code == code }?.name ?? code.rawValue))
                        } else {
                            Text("Choose…").foregroundStyle(.secondary)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                LabeledContent("Amount") {
                    TextField("0.00", text: $model.amountText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .monospacedDigit()
                }

                // The cap, while there is still time to do something about it. Without
                // this the editor took RM 3,000 against a RM 2,500 relief without
                // comment, and the user found out — if ever — by noticing later that the
                // relief's "claimed" and "allowed" figures disagreed.
                if let guidance = model.capGuidance {
                    capNote(guidance)
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
                // A button that reveals the picker, not a toggle labelled "Has a date" —
                // the same shape the dependant editor uses, and better for the same
                // reason: it asks the user to do the thing they want rather than to
                // classify whether the thing is true of their receipt.
                //
                // The three-state care is unchanged. `spentOn` stays nil until the picker
                // is actually moved, so an entry with no date keeps having no date.
                if hasDate {
                    DatePicker("Spent on",
                               selection: Binding(get: { model.spentOn ?? Date() },
                                                  set: { model.spentOn = $0 }),
                               displayedComponents: .date)
                    Button("Remove the date") {
                        hasDate = false
                        model.spentOn = nil
                    }
                    .foregroundStyle(.secondary)
                } else {
                    Button("Set the date spent") { hasDate = true }
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
            .navigationDestination(isPresented: $isPickingRelief) {
                ReliefPickerView(options: model.availableCodes,
                                 selection: $model.selectedCode)
            }
            .task {
                await model.load()
                hasDate = model.spentOn != nil
                #if DEBUG
                if DemoHarness.screen == "relief-picker" { isPickingRelief = true }
                #endif
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

    /// Advice, not an error: secondary type while the amount fits, orange only once part
    /// of it would not count. Save stays enabled either way — LHDN caps what it allows,
    /// it does not stop anyone spending more, and an editor that refused the real figure
    /// would push the user to write down a number that is not what they spent.
    @ViewBuilder
    private func capNote(_ guidance: EntryEditorViewModel.CapGuidance) -> some View {
        // One `Text`, not an `HStack` of `MoneyText` and labels. A sentence built from
        // side-by-side views cannot wrap as a sentence: at this width the first attempt
        // broke into "RM 2,200.00 | of this will not count. | The cap is | RM 2,500.00"
        // with the figures orphaned from the words they belong to. The amounts still come
        // from the one formatter, the same way every accessibility label in the app does.
        if guidance.overBy > .zero {
            Label {
                Text("\(guidance.overBy.formatted()) of this will not count. "
                     + "The cap is \(guidance.cap.formatted()), and "
                     + "\(guidance.headroom.formatted()) of it is left.")
            } icon: {
                Image(systemName: "exclamationmark.circle")
            }
            .font(.footnote)
            .foregroundStyle(.orange)
        } else {
            Text("\(guidance.headroom.formatted()) of this relief is still claimable.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}
