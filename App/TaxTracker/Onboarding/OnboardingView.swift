import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct OnboardingView: View {

    /// `@State` for the same reason every other model-owning screen here is: the caller
    /// builds this view inside its own `body`, so a stored model would be replaced by a
    /// fresh one — resetting the user to step one, mid-answer — on any re-render. Nothing
    /// currently re-renders `RootView` while onboarding is up, which made the old code
    /// correct by luck rather than by construction.
    @State private var model: OnboardingViewModel
    let onFinished: () -> Void

    /// The typed salary lives here rather than on the model because `Money` is not a
    /// string and half-typed text is not a `Money`. It is committed on Done.
    @State private var salaryText = ""
    @State private var startedPartWay = false
    /// Set when the salary the user asked for did not save. The step stays open and says
    /// so — same construction as `IncomeRecordEditor`'s `saveError`. Finishing anyway
    /// would strand them on Home with no tax figures, no explanation, and no second run of
    /// the only screen that asks for a salary.
    @State private var finishError: String?

    init(model: OnboardingViewModel, onFinished: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            stepIndicator(model)

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            VStack(spacing: 12) {
                Button(model.isLastStep ? "Done" : "Continue") {
                    if model.isLastStep {
                        model.monthlySalary = MoneyParsing.money(from: salaryText)
                        Task { await finish() }
                    } else {
                        model.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                if !model.isFirstStep {
                    Button("Back") { model.goBack() }
                        .font(.subheadline)
                }

                Button("Skip for now") {
                    // Unchanged: skipping asks for no income, so nothing can fail to save.
                    Task { await model.skip(); onFinished() }
                }
                .font(.subheadline)
            }
            .padding(24)
        }
    }

    /// Three dots, so the user can see how long this is before deciding to sit through
    /// it. Three skippable screens with no end in sight is a flow people abandon at the
    /// second one — and skipping costs them every relief that depends on a household
    /// fact.
    ///
    /// A back button rides alongside, because onboarding used to run forwards only.
    private func stepIndicator(_ model: OnboardingViewModel) -> some View {
        HStack(spacing: 8) {
            ForEach(OnboardingStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: step == model.step ? 22 : 7, height: 7)
            }
        }
        .padding(.top, 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(model.step.rawValue + 1) of \(OnboardingStep.allCases.count)")
    }

    /// Leaves onboarding only when the writes the user asked for actually happened.
    private func finish() async {
        finishError = nil
        guard await model.finish() == .finished else {
            finishError = "Relio could not save your salary, so it has not finished setting up. Nothing was lost — tap Done to try again, or turn the toggle off to carry on without it."
            return
        }
        onFinished()
    }

    @ViewBuilder
    private var content: some View {
        // `@Bindable` is what turns the `@State`-held observable back into a source of
        // bindings; it is scoped to the block that needs one, per Apple's guidance.
        @Bindable var model = model
        switch model.step {
        case .welcome:
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 12) {
                        Text("Relio").font(.largeTitle.bold())
                        Text("Track your Malaysian tax relief. No account, no server — your data stays on your devices.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Estimates only. Verify with LHDN before you file.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: proxy.size.height)
                }
            }

        case .household:
            Form {
                Section {
                    Picker("Marital status", selection: $model.facts.maritalStatus) {
                        Text("Prefer not to say").tag(MaritalStatus?.none)
                        ForEach(MaritalStatus.allCases, id: \.self) { status in
                            Text(status.rawValue.capitalized).tag(MaritalStatus?.some(status))
                        }
                    }
                    if model.facts.maritalStatus == .married {
                        Toggle("My spouse has income",
                               isOn: Binding(get: { model.facts.spouseHasIncome ?? false },
                                             set: { model.facts.spouseHasIncome = $0 }))
                    }
                } header: {
                    Text("Your household")
                } footer: {
                    Text("You can leave these blank. Relio will ask again when an answer would unlock a relief.")
                }
            }
            .scrollContentBackground(.hidden)

        case .income:
            Form {
                Section {
                    Toggle("Show what relief saves me", isOn: $model.incomeEnabled)
                    if model.incomeEnabled {
                        // A month and a start date, not a year total: those are the two
                        // things a person knows on the day they install the app. The
                        // annual figure is arithmetic Relio should be doing for them.
                        LabeledContent("Income a month") {
                            TextField("0.00", text: $salaryText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                        Toggle("Say when this started", isOn: $startedPartWay)
                        if startedPartWay {
                            // Bounded above by the year being onboarded, and defaulting
                            // to its first day: a date after that year derives RM 0 for
                            // it, which is exactly what today's date would have given a
                            // user onboarding the previous assessment year.
                            DatePicker("Since",
                                       selection: Binding(get: { model.salaryStartedOn ?? IncomeCalendar.startOfYear(model.year) },
                                                          set: { model.salaryStartedOn = $0 }),
                                       in: ...IncomeCalendar.endOfYear(model.year),
                                       displayedComponents: .date)
                        }
                    }
                } footer: {
                    Text(model.incomeEnabled
                         ? "Relio works out the year from this, and you can add raises and bonuses later. Leave the date off if you have earned this all year."
                         : "Optional. Without it Relio still tracks every relief and cap — it just cannot tell you what they are worth in tax.")
                }

                if let finishError {
                    Section {
                        Text(finishError)
                            .foregroundStyle(.orange)
                            .font(.footnote)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            // Turning the toggle back off must clear the date, or a start date the user
            // has visibly retracted would still shorten the year they are onboarding.
            .onChange(of: startedPartWay) { _, isOn in
                if !isOn { model.salaryStartedOn = nil }
            }
        }
    }
}
