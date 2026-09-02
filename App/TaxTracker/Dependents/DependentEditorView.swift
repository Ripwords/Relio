import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// Adding or editing one dependant.
///
/// Every field here decides a relief, and the screen says which as it goes — a form that
/// asks for a date of birth without saying that it is what separates the RM 2,000 child
/// relief from the RM 8,000 one is asking for a favour rather than making a case.
///
/// Nothing defaults, on the same rule the rest of the app follows: a disability status the
/// user never gave must stay `nil` rather than become a `false` the engine reads as an
/// answer.
struct DependentEditorView: View {

    @State private var draft: DependentDraft
    @State private var status: DependentYearStatus
    @State private var isSettingBirthDate: Bool
    @State private var saveFailed = false

    private let year: Int
    private let onSave: (DependentDraft) async -> Bool

    @Environment(\.dismiss) private var dismiss

    init(draft: DependentDraft, year: Int, onSave: @escaping (DependentDraft) async -> Bool) {
        _draft = State(initialValue: draft)
        _status = State(initialValue: draft.yearStatuses.first { $0.year == year }
                        ?? DependentYearStatus(year: year))
        _isSettingBirthDate = State(initialValue: draft.dateOfBirth != nil)
        self.year = year
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    Picker("Relationship", selection: $draft.kind) {
                        ForEach(DependentKind.allCases, id: \.self) { kind in
                            Text(DependentCopy.label(for: kind)).tag(kind)
                        }
                    }
                }

                Section {
                    if isSettingBirthDate {
                        DatePicker("Date of birth",
                                   selection: Binding(get: { draft.dateOfBirth ?? Self.startingDate },
                                                      set: { draft.dateOfBirth = $0 }),
                                   in: ...Date.now,
                                   displayedComponents: .date)
                    } else {
                        // The answer is what the user picks, never what the control happens
                        // to open on — the same rule ContributionQuestionsSheet follows for
                        // the same reason. A date Relio guessed can move a child across the
                        // age 18 threshold, where the relief quadruples.
                        Button("Set a date of birth") { isSettingBirthDate = true }
                    }
                } footer: {
                    // No section header: the row already says "Date of birth", and a
                    // header repeating it put the same three words on screen twice.
                    Text("Age decides which child relief applies: RM 2,000 under 18, and RM 8,000 for full-time tertiary study.")
                }

                if draft.kind == .child {
                    Section {
                        Picker("Studying", selection: $status.educationLevel) {
                            ForEach(EducationLevel.allCases, id: \.self) { level in
                                Text(DependentCopy.label(for: level)).tag(level)
                            }
                        }
                        if status.educationLevel != .none {
                            Toggle("Full time", isOn: $status.isFullTime)
                        }
                    } header: {
                        Text("In \(String(year))")
                    } footer: {
                        Text("Recorded per year, because it changes from year to year. Editing \(String(year)) leaves other years alone.")
                    }

                    Section {
                        Picker("This claim is", selection: $status.claimPercentage) {
                            Text("All mine").tag(100)
                            Text("Split 50/50 with my spouse").tag(50)
                        }
                    } footer: {
                        Text("Parents may split a child relief between them. Claiming the full amount when your spouse also claims it is what LHDN will query.")
                    }
                }

                Section {
                    // Three states, not two: yes, no, and not asked. A Toggle cannot say
                    // the third, and the engine needs it to know whether to prompt.
                    // Short enough to leave the value on the same line. The footer
                    // carries what JKM registration is and what it is worth.
                    Picker("Registered disabled", selection: $draft.isDisabled) {
                        Text("Not said").tag(Bool?.none)
                        Text("Yes").tag(Bool?.some(true))
                        Text("No").tag(Bool?.some(false))
                    }
                } footer: {
                    Text("JKM registration raises a child's relief to RM 8,000, and RM 14,000 while they are in tertiary study.")
                }

                if saveFailed {
                    Section {
                        Label("That could not be saved. Try again.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(draft.name.isEmpty ? "New dependant" : draft.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            var edited = draft
                            // Replace this year's status and leave every other year's
                            // alone: a dependant outlives any one Year of Assessment.
                            edited.yearStatuses.removeAll { $0.year == year }
                            edited.yearStatuses.append(status)
                            if await onSave(edited) {
                                dismiss()
                            } else {
                                // Stays open on a write that did not happen, like every
                                // other editor here.
                                saveFailed = true
                            }
                        }
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    /// Where the date picker opens when the user asks for it. Eighteen years back is the
    /// threshold the child reliefs turn on, so it is the least misleading starting point —
    /// and it is never saved unless the picker is actually moved.
    private static var startingDate: Date {
        Calendar(identifier: .gregorian)
            .date(byAdding: .year, value: -18, to: Date.now) ?? Date.now
    }
}
