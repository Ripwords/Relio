import SwiftUI
import TaxKit
import TaxData
import TaxPresentation

struct EntryHistoryView: View {
    @State private var model: EntryHistoryViewModel

    init(store: TaxStore, year: Int) {
        _model = State(initialValue: EntryHistoryViewModel(store: store, year: year))
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
                                    HStack {
                                        Text(entry.vendor.isEmpty ? "Untitled entry" : entry.vendor)
                                            .font(.headline)
                                        Spacer()
                                        MoneyText(amount: entry.amount, font: .subheadline, weight: .semibold)
                                    }
                                    Text(entry.code.rawValue)
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
                    }
                }
            }
        }
        .navigationTitle("Input history")
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
