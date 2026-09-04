import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

/// The Docs tab: which claims are not yet supported, and by what.
///
/// It replaces a `ContentUnavailableView` reading "Receipt capture arrives in a later
/// release" — a whole tab spent telling the user about something that does not exist.
///
/// Each row opens its entry, where the document can now be attached. The screen is a
/// worklist: what is outstanding, biggest claim first, and one tap to the place that
/// clears it. OCR and MyInvois e-invoices are still to come; picking a photo or a file is
/// not.
struct DocumentsView: View {

    @State private var model: DocumentsViewModel

    init(model: DocumentsViewModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        Group {
            if model.outstanding.isEmpty {
                // Two different empty states, and they were one. "Every claim is
                // supported" under a green tick is vacuously true of nobody's claims, and
                // it told a user who had logged nothing that their filing was in order.
                //
                // Spec §11.5: empty states are the design. A result and a blank are not
                // the same design.
                if model.hasAnyClaims {
                    ContentUnavailableView(
                        "Every claim is supported",
                        systemImage: "checkmark.seal",
                        description: Text("Nothing you have logged is missing a document LHDN asks for."))
                } else {
                    ContentUnavailableView(
                        "Nothing logged yet",
                        systemImage: "doc.text",
                        description: Text("Log a receipt and Relio will list any document LHDN would want alongside it."))
                }
            } else {
                List {
                    Section {
                        ForEach(model.outstanding) { row in
                            NavigationLink(value: EntryRoute(entryID: row.entryID)) {
                                DocumentRowView(row: row)
                            }
                        }
                    } header: {
                        SectionHeading(model.outstanding.count == 1
                                       ? "1 claim needs a document"
                                       : "\(model.outstanding.count) claims need documents")
                    } footer: {
                        // The stake, stated once. Not a per-row figure: repeating it on
                        // every row would read as eight separate risks rather than one
                        // total.
                        // "Come to", not "are worth". This is the sum of what was
                        // entered, and an entry above its relief's cap is worth less than
                        // it says — the same overstatement Home was fixed out of, in one
                        // word. Saying what the figure actually is costs nothing.
                        //
                        // One Text, per the rule on MoneyText: a figure inside a sentence
                        // wraps with its words.
                        Text("Together these claims come to \(model.totalAtRisk.formatted()).")
                            .font(.footnote)
                            .monospacedDigit()
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
        AdaptiveRow {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.vendor.isEmpty ? "Untitled entry" : row.vendor)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    // The family, so a worklist of seven claims can be scanned by area
                    // rather than read line by line.
                    if let category = ReliefCategory(row.code) {
                        Circle()
                            .fill(Theme.tint(category))
                            .frame(width: 7, height: 7)
                    }
                    Text(row.shortName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                // What to go and find. The whole point of the screen.
                Text(missingList)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        } trailing: {
            MoneyText(amount: row.amount, font: Theme.figure(17, .semibold))
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
