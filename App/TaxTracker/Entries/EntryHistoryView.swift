import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct EntryHistoryView: View {
    @State private var model: EntryHistoryViewModel

    init(store: TaxStore, year: Int, restrictedTo: Set<UUID>? = nil) {
        _model = State(initialValue: EntryHistoryViewModel(store: store,
                                                           year: year,
                                                           restrictedTo: restrictedTo))
    }

    var body: some View {
        @Bindable var model = model
        Group {
            if model.filteredEntries.isEmpty {
                ContentUnavailableView("No entries yet", systemImage: "clock.arrow.circlepath",
                                       description: Text(model.searchText.isEmpty ? "Your logged relief inputs will appear here." : "Try a different search.") )
            } else {
                List {
                    Section {
                        ForEach(model.filteredEntries) { entry in
                            NavigationLink(value: EntryRoute(entryID: entry.id)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    AdaptiveRow {
                                        Text(entry.vendor.isEmpty ? "Untitled entry" : entry.vendor)
                                            .font(.headline)
                                    } trailing: {
                                        MoneyText(amount: entry.amount, font: .subheadline, weight: .semibold)
                                    }
                                    // The relief, not its database key. This screen was
                                    // printing "INSURANCE_EDU_MEDICAL" and
                                    // "LIFESTYLE_SPORTS" straight onto the row — the exact
                                    // leak ReliefCopy exists to prevent, and the only
                                    // place left in the app still doing it.
                                    //
                                    // The raw code remains the fallback, which is right:
                                    // a code no rulebook knows has no name to show, and
                                    // those are the entries this screen is filtered to
                                    // when it arrives from Home's unresolved prompt.
                                    Text(ReliefCopy.shortName(for: entry.code,
                                                              fullName: entry.code.rawValue))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if let date = entry.spentOn {
                                        Text(date, style: .date)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    if !entry.note.isEmpty {
                                        Text(entry.note)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                            }
                        }
                    } header: {
                        Text("\(model.filteredEntries.count) inputs")
                    } footer: {
                        // Says why the list is short, so a filtered screen is not mistaken
                        // for the whole history with entries missing from it.
                        if model.restrictedTo != nil {
                            Text("These entries use a relief this year's rules do not "
                                 + "recognise, so they count towards nothing. Open one to "
                                 + "give it a relief that this year has.")
                        }
                    }
                }
            }
        }
        .navigationTitle(model.restrictedTo == nil ? "Input history" : "Needs a relief")
        .searchable(text: $model.searchText, prompt: "Search vendor, note, or relief")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort", selection: $model.sort) {
                        ForEach(EntryHistoryViewModel.Sort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                } label: {
                    Image(systemName: "arrow.up.arrow.down")
                }
                .accessibilityLabel("Sort input history")
            }
        }
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
    }
}
