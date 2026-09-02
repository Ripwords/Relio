import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The Docs tab: which claims are not yet supported, and by what.
///
/// It replaces a `ContentUnavailableView` reading "Receipt capture arrives in a later
/// release" — a whole tab spent telling the user about something that does not exist.
/// Capture genuinely is not built, and this screen does not pretend otherwise. What it
/// does is name the claims LHDN would ask questions about and the document each one
/// needs, which is the part someone can act on today with a drawer and a scanner.
struct DocumentsView: View {

    @State private var model: DocumentsViewModel

    init(model: DocumentsViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if model.outstanding.isEmpty {
                // Spec §11.5: empty states are the design. This one is a result, not a
                // blank — every claim being supported is the state the screen wants.
                ContentUnavailableView(
                    "Every claim is supported",
                    systemImage: "checkmark.seal",
                    description: Text("Nothing you have logged is missing a document LHDN asks for."))
            } else {
                List {
                    Section {
                        ForEach(model.outstanding) { row in
                            NavigationLink(value: EntryRoute(entryID: row.entryID)) {
                                DocumentRowView(row: row)
                            }
                        }
                    } header: {
                        Text(model.outstanding.count == 1
                             ? "1 claim needs a document"
                             : "\(model.outstanding.count) claims need documents")
                    } footer: {
                        // The stake, stated once. Not a per-row figure: repeating it on
                        // every row would read as eight separate risks rather than one
                        // total.
                        HStack(spacing: 4) {
                            Text("Together these claims are worth")
                            MoneyText(amount: model.totalAtRisk, font: .footnote, weight: .semibold)
                        }
                        .font(.footnote)
                    }
                }
            }
        }
        .navigationTitle("Documents")
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}

struct DocumentRowView: View {
    let row: OutstandingDocument

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.vendor.isEmpty ? "Untitled entry" : row.vendor)
                Text(row.shortName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // What to go and find. The whole point of the screen.
                Text(missingList)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 12)
            MoneyText(amount: row.amount, font: .subheadline, weight: .semibold)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var missingList: String {
        row.kinds.map { ReliefCopy.text(for: $0) }
            .formatted(.list(type: .and))
    }

    /// The full relief name here, as everywhere else: length costs a screen reader
    /// nothing, and it says which treatments or purchases the relief covers.
    private var accessibilityLabel: String {
        let vendor = row.vendor.isEmpty ? "Untitled entry" : row.vendor
        return "\(vendor), \(row.amount.formatted()), \(row.reliefName), missing \(missingList)"
    }
}
