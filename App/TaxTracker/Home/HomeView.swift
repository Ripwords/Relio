import SwiftUI
import TaxKit
import TaxPresentation

struct HomeView: View {

    @Bindable var model: HomeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                headline
                prompts
                opportunities
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task { await model.refresh() }
    }

    // The only large number on the screen. Spec §11.
    private var headline: some View {
        VStack(alignment: .leading, spacing: 4) {
            MoneyText(amount: model.headline, font: .system(size: 44), weight: .bold)
                .contentTransition(.numericText())
            Text(model.headlineKind == .taxSaved ? "in tax still claimable" : "of relief still claimable")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var prompts: some View {
        VStack(spacing: 10) {
            if model.prompts.unansweredQuestionCount > 0 {
                promptRow(
                    systemImage: "questionmark.circle",
                    title: model.prompts.unansweredQuestionCount == 1
                        ? "Answer 1 question"
                        : "Answer \(model.prompts.unansweredQuestionCount) questions",
                    trailing: model.prompts.unlockableRelief)
            }
            if model.prompts.claimsMissingDocuments > 0 {
                promptRow(
                    systemImage: "doc.viewfinder",
                    title: model.prompts.claimsMissingDocuments == 1
                        ? "1 claim needs a document"
                        : "\(model.prompts.claimsMissingDocuments) claims need documents",
                    trailing: nil)
            }
            if model.prompts.unresolvedEntryCount > 0 {
                promptRow(
                    systemImage: "exclamationmark.triangle",
                    title: model.prompts.unresolvedEntryCount == 1
                        ? "1 entry uses a relief this year's rules don't recognise"
                        : "\(model.prompts.unresolvedEntryCount) entries use a relief this year's rules don't recognise",
                    trailing: nil)
            }
        }
    }

    private func promptRow(systemImage: String, title: String, trailing: Money?) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
            Text(title)
            Spacer()
            if let trailing {
                HStack(spacing: 4) {
                    Text("unlock")
                    MoneyText(amount: trailing, weight: .semibold)
                }
                .font(.subheadline)
            }
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var opportunities: some View {
        if model.opportunities.isEmpty {
            // Spec §11.5: empty states are the design, not an afterthought.
            VStack(alignment: .leading, spacing: 6) {
                Text("Nothing logged yet")
                    .font(.headline)
                Text("Add your first receipt and Relio will show what it is worth.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } else {
            VStack(alignment: .leading, spacing: 14) {
                Text("Biggest opportunities")
                    .font(.headline)
                ForEach(model.opportunities) { row in
                    OpportunityRowView(row: row)
                }
                if model.remainingOpportunityCount > 0 {
                    Text("See all \(model.remainingOpportunityCount + model.opportunities.count)")
                        .font(.subheadline)
                        .foregroundStyle(.tint)
                }
            }
        }
    }
}

struct OpportunityRowView: View {
    let row: OpportunityRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name)
                ProgressView(value: Double(row.usedPercent), total: 100)
                    .tint(.accentColor)
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 2) {
                MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
                if let saved = row.taxSaved {
                    HStack(spacing: 2) {
                        Text("→")
                        MoneyText(amount: saved, font: .caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
        // Spec §11.8: VoiceOver reads the amounts, never "68 percent".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var label = "\(row.name), \(row.headroom.formatted()) still claimable"
        if let saved = row.taxSaved {
            label += ", worth \(saved.formatted()) in tax"
        }
        if row.needsAnswer {
            label += ", needs an answer first"
        }
        return label
    }
}
