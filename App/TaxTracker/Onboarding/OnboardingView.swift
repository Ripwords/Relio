import SwiftUI
import TaxKit
import TaxPresentation

struct OnboardingView: View {

    /// `@State` for the same reason every other model-owning screen here is: the caller
    /// builds this view inside its own `body`, so a stored model would be replaced by a
    /// fresh one — resetting the user to step one, mid-answer — on any re-render. Nothing
    /// currently re-renders `RootView` while onboarding is up, which made the old code
    /// correct by luck rather than by construction.
    @State private var model: OnboardingViewModel
    let onFinished: () -> Void

    @State private var incomeText = ""

    init(model: OnboardingViewModel, onFinished: @escaping () -> Void) {
        _model = State(initialValue: model)
        self.onFinished = onFinished
    }

    var body: some View {
        @Bindable var model = model
        return VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(24)

            VStack(spacing: 12) {
                Button(model.isLastStep ? "Done" : "Continue") {
                    if model.isLastStep {
                        model.facts.grossIncomeOverride = MoneyParsing.money(from: incomeText)
                        Task { await model.finish(); onFinished() }
                    } else {
                        model.advance()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button("Skip for now") {
                    Task { await model.skip(); onFinished() }
                }
                .font(.subheadline)
            }
            .padding(24)
        }
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
                        LabeledContent("Annual income") {
                            TextField("0.00", text: $incomeText)
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .monospacedDigit()
                        }
                    }
                } footer: {
                    Text("Optional. Without it Relio still tracks every relief and cap — it just cannot tell you what they are worth in tax.")
                }
            }
            .scrollContentBackground(.hidden)
        }
    }
}
