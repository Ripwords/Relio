import SwiftUI
import TaxKit
import TaxPresentation

struct EntryEditorView: View {

    @Bindable var model: EntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    let onDeleted: (EntryEditorViewModel) -> Void

    @State private var hasDate = false

    var body: some View {
        NavigationStack {
            Form {
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
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { if await model.save() { dismiss() } }
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
}
