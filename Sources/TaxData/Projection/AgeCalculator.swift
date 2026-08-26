import Foundation

/// Ages, resolved at the end of a Year of Assessment.
///
/// The engine deliberately never touches a calendar — `DependentSnapshot.ageAtYearEnd`
/// is an already-resolved `Int?` — because a rules engine that reads the clock produces
/// different answers on different days and its golden files rot every 1 January. This is
/// the one place a calendar is consulted, and it takes the year as a parameter rather
/// than reading `Date()`.
public enum AgeCalculator {

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Completed years of age on 31 December of `year`, in Kuala Lumpur.
    public static func age(bornOn birthDate: Date, atEndOf year: Int) -> Int {
        var components = DateComponents()
        components.year = year
        components.month = 12
        components.day = 31
        components.hour = 23
        components.minute = 59
        guard let yearEnd = calendar.date(from: components) else { return 0 }
        return calendar.dateComponents([.year], from: birthDate, to: yearEnd).year ?? 0
    }
}
