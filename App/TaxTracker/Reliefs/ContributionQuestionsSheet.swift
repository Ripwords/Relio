import SwiftUI
import TaxData
import TaxPresentation

/// The payroll facts a contribution floor is blocked on, asked one section at a time.
///
/// Nothing here defaults an answer. Every control starts with nothing selected and Save
/// stays disabled until `model.canSave`, because the store cannot tell an answer apart
/// from a default once it is written, and the whole point of asking is that Relio refuses
/// to guess which statutory rate applies to the user's pay.
struct ContributionQuestionsSheet: View {

    /// `@State`, not a stored `let`: this sheet's content closure runs again every time the
    /// screen presenting it re-renders, and a stored model would be replaced by a fresh
    /// empty one mid-answer, discarding what the user had already picked.
    @State private var model: ContributionQuestionsViewModel

    /// Whether the user has asked for the date picker at all. Separate from the answer
    /// itself, because revealing the control is not the same act as choosing a date.
    @State private var isSettingDateOfBirth = false

    @Environment(\.dismiss) private var dismiss

    /// Overrides the default title.
    ///
    /// "Quick answers" is right when a contribution card sends the user here to unblock a
    /// figure. It is wrong from Settings, where they tapped a row called "Date of birth
    /// and nationality" and would land on a title naming neither.
    private let title: String?

    init(model: ContributionQuestionsViewModel, title: String? = nil) {
        _model = State(initialValue: model)
        self.title = title
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            Form {
                if model.asksDateOfBirth {
                    Section {
                        if isSettingDateOfBirth || model.dateOfBirth != nil {
                            // The answer is whatever the user picks, never what the control
                            // happens to open on. A `DatePicker` cannot report whether it
                            // was moved, but its setter fires only on a real change, so
                            // leaving the answer nil until then is what keeps the date on
                            // screen from becoming a date Relio filed on the user's behalf.
                            // A wrong one here moves someone across the age 60 threshold,
                            // where the EPF rate is 0% and this relief is worth nothing.
                            DatePicker(Self.dateOfBirthPrompt,
                                       selection: Binding(get: { model.dateOfBirth ?? Self.startingDateOfBirth },
                                                          set: { model.dateOfBirth = $0 }),
                                       in: ...Date.now,
                                       displayedComponents: .date)
                                .labelsHidden()
                        } else {
                            Button("Set my date of birth") { isSettingDateOfBirth = true }
                        }
                    } header: {
                        Text(Self.dateOfBirthPrompt)
                    } footer: {
                        if model.dateOfBirth == nil {
                            Text(ReliefCopy.dateOfBirthFooter)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                if model.asksNationality {
                    Section {
                        // Inline, never a menu. The ledger records a menu-style picker
                        // truncating its selection to "A mo…ly rate" at the largest Dynamic
                        // Type size; inline rows are full width and wrap instead.
                        Picker(Self.nationalityPrompt, selection: $model.nationality) {
                            ForEach(NationalityClass.allCases, id: \.self) { value in
                                Text(ReliefCopy.text(for: value)).tag(NationalityClass?.some(value))
                            }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text(Self.nationalityPrompt)
                    }
                }

                ForEach($model.sourceQuestions) { $row in
                    Section {
                        Picker(row.prompt, selection: $row.answer) {
                            Text("Yes").tag(Bool?.some(true))
                            Text("No").tag(Bool?.some(false))
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text(row.prompt)
                    }
                }

                Section {
                    if let saveError = model.saveError {
                        Text(saveError)
                            .foregroundStyle(.orange)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } footer: {
                    Text(ReliefCopy.questionsFooter)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .navigationTitle(title ?? "Quick answers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            // Dismissal is conditional on the write. A sheet that closes on
                            // a failed save takes the user back to a screen still asking the
                            // questions they just answered, with nothing saying why.
                            if await model.save() { dismiss() }
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
            .task { await model.load() }
        }
    }

    private static let dateOfBirthPrompt = ReliefCopy.prompt(for: .dateOfBirth, sourceNamed: "")
    private static let nationalityPrompt = ReliefCopy.prompt(for: .nationality, sourceNamed: "")

    /// Where the picker opens once the user has said they want to set a date: 1 January
    /// thirty years ago, so most people scroll rather than spin through decades.
    ///
    /// Built through `IncomeCalendar`, which fixes the calendar and the zone at
    /// Asia/Kuala_Lumpur. A date of birth decides which statutory rate applies to a month
    /// of pay, and it must not come out a day different on a device set to another zone.
    private static var startingDateOfBirth: Date {
        IncomeCalendar.startOfYear(IncomeCalendar.year(of: .now) - 30)
    }
}
