import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// Spec §7: the generic rule diff is not the feature worth building — the personalised
/// counterfactual is. This screen replays the user's own entries under another year's
/// rulebook and prices the difference, which is the only version of "what changed" that
/// answers "and what is that worth to me?".
struct CompareView: View {

    @State private var model: CompareViewModel

    init(model: CompareViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        List {
            Section {
                Picker("Compare with", selection: comparisonBinding) {
                    ForEach(model.comparisonYears, id: \.self) { year in
                        Text("YA \(String(year))").tag(year)
                    }
                }
            }

            if let result = model.result {
                Section {
                    headline
                } footer: {
                    Text("Your \(String(model.baselineYear)) entries, evaluated under \(String(model.comparisonYear))'s rules. Estimate only.")
                }

                if !result.lines.isEmpty {
                    Section {
                        ForEach(result.lines) { line in
                            CounterfactualRowView(line: line,
                                                  baselineYear: model.baselineYear,
                                                  comparisonYear: model.comparisonYear)
                        }
                    } header: {
                        Text("What moved for you")
                    } footer: {
                        Text("Reliefs you claimed that the two years treat differently.")
                    }
                }

                if !model.ruleChanges.isEmpty {
                    Section {
                        ForEach(model.ruleChanges, id: \.self) { delta in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(ReliefCopy.name(of: delta))
                                Text(ReliefCopy.text(for: delta, in: max(model.baselineYear, model.comparisonYear)))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    } header: {
                        Text("Other changes")
                    } footer: {
                        // Says why they carry no figure, so their absence does not read
                        // as the app failing to price them.
                        Text("These rules changed too. You have nothing logged against them, so they are worth nothing to you either way.")
                    }
                }

                if result.lines.isEmpty && model.ruleChanges.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No difference for you",
                            systemImage: "equal.circle",
                            description: Text("Nothing you logged is treated differently between these two years."))
                    }
                }
            } else if case .unavailable(let message) = model.status {
                ContentUnavailableView("Cannot compare",
                                       systemImage: "calendar.badge.exclamationmark",
                                       description: Text(message))
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Compare")
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.refresh() }
    }

    private var comparisonBinding: Binding<Int> {
        Binding(get: { model.comparisonYear },
                set: { year in Task { await model.compare(with: year) } })
    }

    /// The direction is said in words, not carried by a minus sign. A negative ringgit
    /// figure at the top of a tax screen reads as "you owe this".
    @ViewBuilder
    private var headline: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(headlineText)
                .font(.headline)
            if model.direction != .noDifference {
                // One Text each, not a figure beside a label. Side by side these wrapped
                // into "RM 500.00 | more" over "relief" at the largest type sizes — the
                // same break the entry editor's cap note and Home's unlock row had.
                Text("\(model.headlineAmount.formatted()) more relief")
                    .font(.title2.weight(.bold))
                    .monospacedDigit()
                if let tax = model.headlineTax {
                    Text("\(tax.formatted()) in tax")
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private var headlineText: String {
        switch model.direction {
        case .betterOff:
            "\(String(model.baselineYear))'s rules leave you better off"
        case .worseOff:
            "\(String(model.comparisonYear))'s rules would have left you better off"
        case .noDifference:
            "These two years treat your entries the same"
        }
    }
}

struct CounterfactualRowView: View {
    let line: CounterfactualLine
    let baselineYear: Int
    let comparisonYear: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ReliefCopy.shortName(for: line.code, fullName: line.name))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    yearFigure(comparisonYear, line.allowedUnderComparison)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    yearFigure(baselineYear, line.allowedUnderBaseline)
                    Spacer(minLength: 8)
                }
                // Two figures and an arrow cannot share a line at accessibility sizes.
                // Stacked, the arrow would point sideways at nothing, so it goes.
                VStack(alignment: .leading, spacing: 4) {
                    yearFigure(comparisonYear, line.allowedUnderComparison)
                    yearFigure(baselineYear, line.allowedUnderBaseline)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private func yearFigure(_ year: Int, _ amount: Money) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("YA \(String(year))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            MoneyText(amount: amount, font: .subheadline, weight: .semibold)
        }
    }

    /// The full name, and the direction spelled out. "Up" and "down" rather than a signed
    /// figure, because VoiceOver reads a minus as "minus" and that is not what it means.
    private var accessibilityLabel: String {
        let movement = line.difference.sen > 0 ? "up" : "down"
        let size = Money(sen: abs(line.difference.sen))
        return "\(line.name), \(movement) \(size.formatted()) in \(String(baselineYear)) "
             + "compared with \(String(comparisonYear))"
    }
}
