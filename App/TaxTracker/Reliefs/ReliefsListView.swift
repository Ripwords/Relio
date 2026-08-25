import SwiftUI
import TaxKit
import TaxPresentation

struct ReliefsListView: View {

    @Bindable var model: ReliefsListViewModel

    var body: some View {
        List {
            ForEach(model.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        NavigationLink(value: row.code) {
                            ReliefRowView(row: row)
                        }
                    }
                }
            }
        }
        .navigationTitle("Reliefs")
        .searchable(text: $model.searchText, prompt: "Search reliefs")
        .onChange(of: model.searchText) { model.refresh() }
        .onAppear { model.refresh() }
        .overlay {
            if model.sections.isEmpty {
                ContentUnavailableView.search(text: model.searchText)
            }
        }
    }
}

struct ReliefRowView: View {
    let row: ReliefRow

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text(row.name)
                if row.state == .claimable || row.state == .exhausted {
                    ProgressView(value: Double(row.usedPercent), total: 100)
                        .tint(row.state == .exhausted ? .secondary : .accentColor)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var trailing: some View {
        switch row.state {
        case .claimable:
            MoneyText(amount: row.headroom, font: .subheadline, weight: .semibold)
        case .exhausted:
            Text("Full").font(.subheadline).foregroundStyle(.secondary)
        case .needsAnswer:
            Image(systemName: "questionmark.circle").foregroundStyle(.tint)
        case .unavailable:
            Text("N/A").font(.subheadline).foregroundStyle(.secondary)
        }
    }

    /// Spec §11.8: "Lifestyle, RM 1,700 of RM 2,500 used", never "68 percent".
    private var accessibilityLabel: String {
        switch row.state {
        case .claimable, .exhausted:
            return "\(row.name), \(row.allowed.formatted()) of \(row.cap.formatted()) used"
        case .needsAnswer:
            return "\(row.name), needs an answer before it can be claimed"
        case .unavailable:
            return "\(row.name), not applicable to you"
        }
    }
}
