import Foundation

public struct DateCandidate: Hashable, Sendable {
    /// Noon in Asia/Kuala_Lumpur, the way entry dates are stored.
    public var date: Date
    /// Day and month are both 12 or under and differ, so `04/05` could be either. Read
    /// day-first — Malaysia's convention — at reduced confidence.
    public var ambiguous: Bool
}

/// Dates as Malaysian receipts print them, read day-first.
public enum ReceiptDate {

    public static let timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    /// English and Malay month names, by their first three letters. `mac`, `mei`, `ogo`,
    /// `okt` and `dis` are the Malay ones that differ from English.
    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "mac": 3, "apr": 4, "may": 5, "mei": 5,
        "jun": 6, "jul": 7, "aug": 8, "ogo": 8, "sep": 9, "oct": 10, "okt": 10,
        "nov": 11, "dec": 12, "dis": 12,
    ]

    public static func noon(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        var parts = DateComponents()
        parts.year = year; parts.month = month; parts.day = day; parts.hour = 12
        guard let date = calendar.date(from: parts) else { return nil }
        // `Calendar` rolls 31 February over into March. Reading it back is what refuses it.
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    public static func dates(in line: String, now: Date) -> [DateCandidate] {
        var found: [(Int, Int, Int, Bool)] = []   // year, month, day, ambiguous

        // Swift's Regex has no lookbehind, so "no digit immediately before" is checked
        // by hand (`startsCleanly`). With the lookaheads, that stops a phone number or an
        // ID containing digit runs being read as a date.
        let iso = /(\d{4})[-\/.](\d{1,2})[-\/.](\d{1,2})(?!\d)/
        let numeric = /(\d{1,2})[-\/.](\d{1,2})[-\/.](\d{4}|\d{2})(?![\d\/.-])/
        let named = /(?i)(\d{1,2})[ -]([a-z]{3,9})[ ,-]+(\d{4}|\d{2})(?!\d)/

        func startsCleanly(_ range: Range<String.Index>) -> Bool {
            range.lowerBound == line.startIndex
                || !line[line.index(before: range.lowerBound)].isNumber
        }

        for match in line.matches(of: iso) where startsCleanly(match.range) {
            guard let y = Int(match.output.1), let m = Int(match.output.2),
                  let d = Int(match.output.3) else { continue }
            found.append((y, m, d, false))
        }
        for match in line.matches(of: numeric) where startsCleanly(match.range) {
            guard let d = Int(match.output.1), let m = Int(match.output.2),
                  let rawYear = Int(match.output.3) else { continue }
            let y = match.output.3.count == 2 ? 2000 + rawYear : rawYear
            found.append((y, m, d, d <= 12 && m <= 12 && d != m))
        }
        for match in line.matches(of: named) where startsCleanly(match.range) {
            let name = match.output.2.lowercased()
            guard let d = Int(match.output.1), let rawYear = Int(match.output.3),
                  let m = months[String(name.prefix(3))] else { continue }
            let y = match.output.3.count == 2 ? 2000 + rawYear : rawYear
            found.append((y, m, d, false))
        }

        let today = startOfDay(now)
        guard let earliest = calendar.date(byAdding: .year, value: -7, to: today) else { return [] }
        return found.compactMap { y, m, d, ambiguous in
            guard let date = noon(y, m, d),
                  startOfDay(date) <= today,
                  date >= earliest else { return nil }
            return DateCandidate(date: date, ambiguous: ambiguous)
        }
    }

    private static func startOfDay(_ date: Date) -> Date { calendar.startOfDay(for: date) }
}
