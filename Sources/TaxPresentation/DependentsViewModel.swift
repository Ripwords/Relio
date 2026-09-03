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

    /// The year the ages and statuses are read for. Taken from the context rather than
    /// passed alongside it, so the two cannot drift apart when the user switches year.
    public var year: Int { context.year }

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
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

    /// Saving re-evaluates the year, not just this list.
    ///
    /// A dependant is an input to eligibility — a child under 18 is what makes
    /// CHILD_UNDER_18 claimable at all — so adding one changes what every other screen
    /// should say. Without the reload the user added a child, watched the list grow, and
    /// saw the child reliefs stay exactly as unavailable as they were.
    @discardableResult
    public func save(_ draft: DependentDraft) async -> Bool {
        do {
            _ = try await store.save(draft)
            await context.reload()
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
            await context.reload()
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
        await context.reload()
        await refresh()
    }

    public func clearUndo() { lastDeleted = nil }
}
