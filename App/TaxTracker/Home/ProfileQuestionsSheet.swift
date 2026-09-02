import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The screen behind Home's "Answer 3 questions — unlock RM 20,000".
///
/// That prompt has been on Home since the first build with nothing behind it. The engine's
/// three-valued eligibility exists so an unasked question reads as "answer this and find
/// out" instead of a silent "you don't qualify", and none of that design reaches the user
/// until something can take the answer.
///
/// Nothing here defaults, for the same reason `ContributionQuestionsSheet` does not: once
/// written, the store cannot tell an answer from a default, and every one of these facts
/// changes what Relio tells someone they can claim.
struct ProfileQuestionsSheet: View {

    /// `@State`, not a stored `let`: a sheet's content closure runs again whenever the
    /// presenting screen re-renders, and a stored model would be swapped for a fresh empty
    /// one mid-answer, discarding what the user had already picked.
    @State private var model: ProfileQuestionsViewModel

    /// Half-typed text is not a `Money`, so the field owns a string and commits on change.
    @State private var propertyPriceText = ""

    @Environment(\.dismiss) private var dismiss

    let onSaved: () -> Void

    /// Overrides the count-based title. "3 questions" names the task Home sent the user
    /// here to finish; opened from Settings there is no task, only a profile.
    private let title: String?

    init(model: ProfileQuestionsViewModel,
         title: String? = nil,
         onSaved: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.title = title
        self.onSaved = onSaved
    }

    var body: some View {
        @Bindable var model = model
        return NavigationStack {
            Form {
                ForEach(model.questions, id: \.self) { question in
                    Section {
                        control(for: question, model: model)
                    } header: {
                        Text(ReliefCopy.question(for: question))
                            .textCase(nil)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                    } footer: {
                        Text(ReliefCopy.reasonForAsking(question))
                    }
                }

                if let error = model.saveError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle(title ?? (model.questions.count == 1
                                       ? "One question"
                                       : "\(model.questions.count) questions"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await model.save()
                            // Only leave on a write that happened. A sheet that dismisses
                            // over a failed save tells the user they answered when they
                            // did not — the failure onboarding was fixed for.
                            guard model.saveError == nil else { return }
                            onSaved()
                            dismiss()
                        }
                    }
                    .disabled(!model.canSave)
                }
            }
        }
    }

    @ViewBuilder
    private func control(for question: ProfileQuestion,
                         model: ProfileQuestionsViewModel) -> some View {
        switch question {
        case .maritalStatus:
            choice($model.maritalStatus, MaritalStatus.allCases, label: Self.label(for:))
        case .assessmentType:
            choice($model.assessmentType, AssessmentType.allCases, label: Self.label(for:))
        case .employmentType:
            choice($model.employmentType, EmploymentType.allCases, label: Self.label(for:))
        case .gender:
            choice($model.gender, Gender.allCases, label: Self.label(for:))
        case .spouseHasIncome:
            yesNo($model.spouseHasIncome)
        case .disabilityStatus:
            yesNo($model.selfIsDisabled)
        case .spouseDisabilityStatus:
            yesNo($model.spouseIsDisabled)
        case .propertyPrice:
            LabeledContent("Price") {
                TextField("0.00", text: $propertyPriceText)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: propertyPriceText) {
                        model.propertyPrice = MoneyParsing.money(from: propertyPriceText)
                    }
            }
        case .dependentDetails, .lastClaimYear:
            // `ProfileQuestionsViewModel.answerable` filters both of these out before the
            // list is built, so this is unreachable. It exists so that adding a
            // `ProfileQuestion` case fails to compile here rather than rendering nothing.
            EmptyView()
        }
    }

    /// One row per option, ticked rather than a wheel. A `Picker` shows a value before the
    /// user has chosen one, which is exactly the "is this an answer or a default?"
    /// ambiguity every control on this screen is built to avoid.
    @ViewBuilder
    private func choice<Value: Hashable>(_ selection: Binding<Value?>,
                                         _ options: [Value],
                                         label: @escaping (Value) -> String) -> some View {
        ForEach(options, id: \.self) { option in
            Button {
                selection.wrappedValue = option
            } label: {
                HStack {
                    Text(label(option)).foregroundStyle(.primary)
                    Spacer()
                    if selection.wrappedValue == option {
                        Image(systemName: "checkmark").foregroundStyle(.tint)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func yesNo(_ selection: Binding<Bool?>) -> some View {
        choice(selection, [true, false]) { $0 ? "Yes" : "No" }
    }

    private static func label(for value: MaritalStatus) -> String {
        switch value {
        case .single: "Single"
        case .married: "Married"
        case .divorced: "Divorced"
        case .widowed: "Widowed"
        }
    }

    private static func label(for value: AssessmentType) -> String {
        switch value {
        case .separate: "Separately"
        case .joint: "Jointly, in my name"
        case .combinedUnderSpouse: "Jointly, under my spouse"
        }
    }

    private static func label(for value: EmploymentType) -> String {
        switch value {
        case .privateSector: "Private sector"
        case .publicServantPensionable: "Public service, pensionable"
        case .selfEmployed: "Self-employed"
        }
    }

    private static func label(for value: Gender) -> String {
        switch value {
        case .female: "Female"
        case .male: "Male"
        case .unspecified: "Prefer not to say"
        }
    }
}
