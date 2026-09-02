import Foundation
import Observation
import TaxKit
import TaxData

/// One dependant, as the list shows them.
public struct DependentRow: Hashable, Sendable, Identifiable {
    public var draft: DependentDraft
    /// Age at the end of the year being viewed, which is the age every child relief is
    /// decided on — not age today.
    public var age: Int?
    /// This year's education level and claim share, when one has been recorded.
    public var status: DependentYearStatus?

    public var id: UUID { draft.id }
    public var name: String { draft.name }
    public var kind: DependentKind { draft.kind }
}

/// The household the child, parent and grandparent reliefs are claimed for.
///
/// Nothing in the app could add one. `EntryEditorView` has always had a "Which person"
/// picker reading `store.dependentDrafts()`, and no screen ever wrote to it — so the
/// picker was permanently empty, the five child reliefs were unclaimable, and
/// `ProfileQuestion.dependentDetails` had nowhere to be answered. For a Malaysian family
/// those are among the most valuable reliefs in the rulebook.
@MainActor
@Observable
public final class DependentsViewModel {

    public private(set) var dependents: [DependentRow] = []

    /// What the last delete removed, so the toast can put it back. Spec §11.6.
    public private(set) var lastDeleted: DependentDraft?

    public let year: Int
    private let store: TaxStore

    public init(store: TaxStore, year: Int) {
        self.store = store
        self.year = year
    }

    public func refresh() async {
        let drafts = (try? await store.dependentDrafts()) ?? []
        dependents = drafts
            .map { draft in
                DependentRow(draft: draft,
                             age: draft.dateOfBirth.map {
                                 AgeCalculator.age(bornOn: $0, atEndOf: year)
                             },
                             status: draft.yearStatuses.first { $0.year == year })
            }
            // Kind first, then name: a household reads as children, then parents, then
            // grandparents. Ties break on id so the list cannot reshuffle between launches.
            .sorted { left, right in
                if left.kind != right.kind {
                    return Self.order(left.kind) < Self.order(right.kind)
                }
                if left.name != right.name { return left.name < right.name }
                return left.id.uuidString < right.id.uuidString
            }
    }

    private static func order(_ kind: DependentKind) -> Int {
        switch kind {
        case .child: 0
        case .parent: 1
        case .grandparent: 2
        }
    }

    @discardableResult
    public func save(_ draft: DependentDraft) async -> Bool {
        do {
            _ = try await store.save(draft)
            await refresh()
            return true
        } catch {
            await refresh()
            return false
        }
    }

    /// Soft delete, and remember enough to offer it back.
    @discardableResult
    public func delete(id: UUID) async -> Bool {
        // Captured before the delete: afterwards the row is gone from the drafts and the
        // toast would have no name to show.
        let removed = dependents.first { $0.id == id }?.draft
        do {
            try await store.softDeleteDependent(id: id)
            lastDeleted = removed
            await refresh()
            return true
        } catch {
            await refresh()
            return false
        }
    }

    public func undoDelete() async {
        guard let lastDeleted else { return }
        try? await store.restoreDependent(id: lastDeleted.id)
        self.lastDeleted = nil
        await refresh()
    }

    public func clearUndo() { lastDeleted = nil }
}
