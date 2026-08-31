import Foundation
import Observation
import TaxKit
import TaxData

@MainActor
@Observable
public final class EntryHistoryViewModel {
    public var entries: [EntryDraft] = []
    public var searchText = ""
    public var sort: Sort = .newest

    public enum Sort: String, CaseIterable, Sendable {
        case newest = "Newest"
        case oldest = "Oldest"
        case highestAmount = "Highest amount"
    }

    private let store: TaxStore
    private let year: Int

    public init(store: TaxStore, year: Int) {
        self.store = store
        self.year = year
    }

    public var filteredEntries: [EntryDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let matching = entries.filter { entry in
            query.isEmpty || entry.vendor.localizedCaseInsensitiveContains(query)
                || entry.note.localizedCaseInsensitiveContains(query)
                || entry.code.rawValue.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .newest:
            return matching.sorted { ($0.spentOn ?? .distantPast, $0.id.uuidString) > ($1.spentOn ?? .distantPast, $1.id.uuidString) }
        case .oldest:
            return matching.sorted { ($0.spentOn ?? .distantFuture, $0.id.uuidString) < ($1.spentOn ?? .distantFuture, $1.id.uuidString) }
        case .highestAmount:
            return matching.sorted { ($0.amount.sen, $0.id.uuidString) > ($1.amount.sen, $1.id.uuidString) }
        }
    }

    public func refresh() async {
        entries = (try? await store.entryDrafts(forYear: year)) ?? []
    }
}
