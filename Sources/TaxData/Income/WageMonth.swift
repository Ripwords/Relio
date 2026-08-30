import Foundation

/// One calendar month of wages in Kuala Lumpur.
///
/// The join key `IncomeCalendar.MonthSpan` lacks. A `MonthSpan` is the pro-rating fraction
/// and nothing else, so a mid-month raise arrives as two slices of April that nothing can
/// put back together. EPF and SOCSO are both assessed on a *month's wage* rather than on
/// either slice, and every statutory fact downstream — which insured-wage ceiling is in
/// force, which side of an age threshold the month falls on — is keyed to the month too.
/// So the month has to be a value the slices can be grouped by.
public struct WageMonth: Hashable, Sendable, Comparable, Codable {
    public let year: Int
    /// 1...12, as `Calendar` numbers months.
    public let month: Int

    public init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// The month `date` falls in, resolved through `IncomeCalendar`.
    ///
    /// That calendar and no other: two devices in different time zones must assess a wage
    /// against the same month, and a payment near midnight on 31 December must not become
    /// a December wage on one of them and a January wage on the other.
    public init(containing date: Date) {
        self.init(year: IncomeCalendar.year(of: date), month: IncomeCalendar.month(of: date))
    }

    /// Chronological. Comparing the month alone would sort December 2024 after January
    /// 2025, and a statutory era keyed to a wage month would then cover the wrong months.
    public static func < (lhs: WageMonth, rhs: WageMonth) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        return lhs.month < rhs.month
    }
}
