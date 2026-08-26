import Foundation

/// Navigation value for the full reliefs list.
///
/// A distinct type (rather than reusing an existing marker) because `NavigationStack`
/// dispatches on type identity: `ReliefsRoute` and `ReliefCode` can share one path
/// without colliding, and this route needs no payload of its own.
struct ReliefsRoute: Hashable {}

/// Navigation value for a single logged entry.
struct EntryRoute: Hashable {
    let entryID: UUID
}

/// Navigation value for the income timeline.
struct IncomeRoute: Hashable {}
