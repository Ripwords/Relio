import Foundation
import TaxKit

/// Turns what a user typed into `Money`, without `Double`.
///
/// `Double(text)` would introduce exactly the representation error `Money` exists to
/// prevent, at the one point where the user's own figure enters the system. `Decimal`
/// parses the digits exactly and `Money(ringgit:)` rounds half-up at the sen boundary.
public enum MoneyParsing {

    public static func money(from text: String) -> Money? {
        let cleaned = text
            .replacingOccurrences(of: "RM", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: "\u{00A0}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty,
              cleaned.filter({ $0 == "." }).count <= 1,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" }),
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
        else { return nil }

        return Money(ringgit: decimal)
    }
}
