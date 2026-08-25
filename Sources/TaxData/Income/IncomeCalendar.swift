import Foundation

/// Day-level calendar arithmetic for income, in Kuala Lumpur.
///
/// Fixed calendar, fixed zone, POSIX locale — the same discipline `AgeCalculator` and
/// `Normalisation` follow. Two devices in different time zones must derive the same income
/// for the same household, and a payment near midnight must belong to the same year on
/// both.
///
/// Nothing here reads `Date()`. Every function takes the dates it works on.
public enum IncomeCalendar {

    /// Days of a span that fall inside one calendar month, with that month's length.
    /// Pro-rating needs both: fourteen days of April is `14/30`, of February `14/28`.
    public struct MonthSpan: Hashable, Sendable {
        public let days: Int
        public let daysInMonth: Int

        public init(days: Int, daysInMonth: Int) {
            self.days = days
            self.daysInMonth = daysInMonth
        }
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")
            ?? TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    public static func year(of date: Date) -> Int {
        calendar.component(.year, from: date)
    }

    public static func startOfDay(_ date: Date) -> Date {
        calendar.startOfDay(for: date)
    }

    public static func dayBefore(_ date: Date) -> Date {
        calendar.date(byAdding: .day, value: -1, to: startOfDay(date)) ?? date
    }

    public static func startOfYear(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = 1; components.day = 1
        return calendar.date(from: components) ?? .distantPast
    }

    public static func endOfYear(_ year: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = 12; components.day = 31
        return calendar.date(from: components) ?? .distantFuture
    }

    /// Splits an inclusive day range into per-month spans, in calendar order.
    ///
    /// Both ends are inclusive: 1–14 April is fourteen days. That is the off-by-one the
    /// whole derivation turns on, and it is why this returns days rather than a duration.
    public static func monthSpans(from start: Date, through end: Date) -> [MonthSpan] {
        let first = startOfDay(start)
        let last = startOfDay(end)
        guard first <= last else { return [] }   // an inverted span contributes nothing

        var spans: [MonthSpan] = []
        var cursor = first

        while cursor <= last {
            guard let monthRange = calendar.range(of: .day, in: .month, for: cursor),
                  let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: cursor)),
                  let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart)
            else {
                // This is a money path: a truncated span here undercounts income. These
                // `Calendar` lookups do not fail for any real Gregorian date, so reaching
                // this branch means a sentinel (e.g. `.distantPast`/`.distantFuture` from
                // `startOfYear`/`endOfYear`'s fallbacks) made it in as `cursor`. Trap in
                // debug/test so it's caught in development; degrade — stop accumulating
                // rather than crash — in a shipped build.
                assertionFailure("IncomeCalendar.monthSpans: Calendar lookup failed for cursor \(cursor); truncating span rather than under- or over-counting income.")
                break
            }

            let monthEnd = dayBefore(nextMonth)
            let spanEnd = min(monthEnd, last)
            let days = (calendar.dateComponents([.day], from: cursor, to: spanEnd).day ?? 0) + 1
            spans.append(MonthSpan(days: days, daysInMonth: monthRange.count))

            let advanced = calendar.date(byAdding: .day, value: 1, to: spanEnd)
            if advanced == nil {
                // Same rationale: advancing the cursor by one day should never fail for a
                // real date. If it does, the `??` fallback below jumps the cursor a fixed
                // day past `last` so the loop still terminates — but that jump is itself a
                // silent skip on a money path, so trap it in debug/test.
                assertionFailure("IncomeCalendar.monthSpans: could not advance cursor past \(spanEnd); falling back to a fixed day past `last`.")
            }
            cursor = advanced ?? last.addingTimeInterval(86_400)
        }
        return spans
    }
}
