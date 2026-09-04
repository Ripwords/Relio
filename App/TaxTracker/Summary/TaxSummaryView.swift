import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The whole calculation, from gross income to the tax owed.
///
/// Home leads with what is still claimable, which is the last line of a five-line sum the
/// engine has always computed and never shown. Someone tracking relief wants the other
/// four: what they earned, what the relief came to, what is left to tax, and what that
/// tax is.
///
/// Reached by tapping the headline, which is the same move the relief detail makes — the
/// figure is the button to how it was worked out.
struct TaxSummaryView: View {

    let summary: TaxSummary
    let year: Int

    var body: some View {
        List {
            Section {
                line("Gross income", summary.grossIncome)
                line("Relief allowed", summary.reliefAllowed, subtracted: true)
                line("Chargeable income", summary.chargeableIncome, emphasised: true)
            } header: {
                SectionHeading("In \(String(year))")
            } footer: {
                Text("Relief comes off your income before tax is worked out. Chargeable income is what is left.")
            }

            Section {
                line("Estimated tax", summary.estimatedTax, emphasised: true)
                if let claimable = summary.stillClaimable, claimable > .zero {
                    // No minus sign, and named as a possibility rather than a deduction.
                    // Set as "Still claimable − RM 8,248.50" under "Estimated tax
                    // RM 8,583.00" it read as a running sum, inviting the reader to do the
                    // subtraction and conclude they owe RM 334.50. They do not: that
                    // figure is what claiming every remaining relief would be worth, and
                    // claiming them means actually spending the money first.
                    line("Could still save", claimable)
                }
            } footer: {
                if let claimable = summary.stillClaimable, claimable > .zero {
                    Text("Using every relief you still have room for would take about "
                         + "\(claimable.formatted()) off that. Estimate only — verify with "
                         + "LHDN before you file.")
                } else {
                    Text("Estimate only. Verify with LHDN before you file.")
                }
            }
        }
        .navigationTitle("Your tax")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A label and a figure, stacking when they cannot share a line. `AdaptiveRow` is the
    /// shared one; these rows also carry a minus sign for the two lines that come off the
    /// total, because a column of positive figures gives no clue which way each one runs.
    private func line(_ title: String,
                      _ amount: Money,
                      subtracted: Bool = false,
                      emphasised: Bool = false) -> some View {
        AdaptiveRow {
            Text(title)
                .fontWeight(emphasised ? .semibold : .regular)
        } trailing: {
            HStack(spacing: 2) {
                if subtracted {
                    Text("−").foregroundStyle(.secondary)
                }
                MoneyText(amount: amount,
                          font: Theme.figure(emphasised ? 20 : 17,
                                             emphasised ? .semibold : .regular))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(subtracted
                            ? "\(title), minus \(amount.formatted())"
                            : "\(title), \(amount.formatted())")
    }
}
