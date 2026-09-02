import Foundation
import TaxKit

/// Navigation value for a single logged entry.
struct EntryRoute: Hashable {
    let entryID: UUID
}

/// Navigation value for the income timeline.
struct IncomeRoute: Hashable {}

struct EntryHistoryRoute: Hashable {}

/// Navigation value for a new entry that opens with a figure already in it.
///
/// A route rather than a flag on `EntryRoute`: that one names an entry that exists, and
/// this one names one that does not yet, so the editor must not try to load it.
struct PrefilledEntryRoute: Hashable {
    let code: ReliefCode
    let amount: Money
}

/// Navigation value for Settings.
struct SettingsRoute: Hashable {}

/// Navigation value for the year comparison.
struct CompareRoute: Hashable {}
