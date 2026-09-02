import Foundation
import TaxKit

/// Navigation value for a single logged entry.
struct EntryRoute: Hashable {
    let entryID: UUID
}

/// Navigation value for the income timeline.
struct IncomeRoute: Hashable {}

/// The input history, optionally narrowed to a named set of entries.
///
/// `nil` is the whole year — the ordinary Settings route. Home's "entries use a relief
/// this year's rules don't recognise" prompt passes the ids the evaluator could not
/// resolve, so the tap lands on exactly the rows that need re-coding.
struct EntryHistoryRoute: Hashable {
    var restrictedTo: Set<UUID>?
}

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
