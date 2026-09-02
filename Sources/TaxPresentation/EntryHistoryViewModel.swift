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

    /// When set, the screen shows only these entries.
    ///
    /// Home's "N entries use a relief this year's rules don't recognise" prompt was the
    /// last row on that screen with nothing behind the tap. `UnresolvedEntry` even
    /// documents itself as existing "so the UI can show an actionable amber row instead
    /// of dropping the claim" — and the row was not actionable.
    ///
    /// A filter on this screen rather than a screen of its own: the user needs to open
    /// the entry and change its relief, which is exactly what these rows already do.
    public var restrictedTo: Set<UUID>?

    public enum Sort: String, CaseIterable, Sendable {
        case newest = "Newest"
        case oldest = "Oldest"
        case highestAmount = "Highest amount"
    }

    private let store: TaxStore
    private let year: Int

    public init(store: TaxStore, year: Int, restrictedTo: Set<UUID>? = nil) {
        self.store = store
        self.year = year
        self.restrictedTo = restrictedTo
    }

    public var filteredEntries: [EntryDraft] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).localizedLowercase
        let matching = entries.filter { entry in
            guard restrictedTo?.contains(entry.id) ?? true else { return false }
            return query.isEmpty || entry.vendor.localizedCaseInsensitiveContains(query)
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
