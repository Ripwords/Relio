import Foundation

/// Canonical forms for the fields that go into a dedupe key.
///
/// Every one of these must be device-independent. Two phones that disagree about the
/// spelling of a vendor or the day of a purchase produce two keys for one receipt, and
/// the reconciliation sweep then never converges — it would keep both rows forever and
/// the user would see the duplicate the sweep exists to remove.
public enum Normalisation {

    /// Case- and diacritic-folded, reduced to alphanumeric words joined by single spaces.
    public static func vendor(_ raw: String) -> String {
        raw.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// `yyyy-MM-dd` in Kuala Lumpur, or `""` for an unknown date.
    ///
    /// Fixed zone, fixed calendar, POSIX locale: the device's own settings must not
    /// change the answer. A purchase at 05:20 on 20 February in KL is still 19 February
    /// in UTC, and the two must not hash differently.
    public static func day(_ instant: Date?) -> String {
        guard let instant else { return "" }
        return dayFormatter.string(from: instant)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? TimeZone(secondsFromGMT: 8 * 3600)!
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
