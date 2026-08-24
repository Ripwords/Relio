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

        // No "-" at all, not just no leading "-": `Decimal(string:)` stops at the first
        // character it cannot parse rather than failing outright, so `"5-3"` silently
        // becomes RM 5.00 and `"1-2.5"` becomes RM 1.00 — a typo that produces a wrong
        // amount, which is worse than one that produces no amount. Validation already
        // refuses zero and negative amounts, so nothing downstream needed "-" anyway.
        guard !cleaned.isEmpty,
              cleaned.filter({ $0 == "." }).count <= 1,
              cleaned.allSatisfy({ $0.isNumber || $0 == "." }),
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")),
              // `Money(ringgit:)` traps via `precondition` outside `Int`'s range — a
              // typed amount is the one place that precondition can be reached with
              // attacker- or fat-finger-controlled input, and it must fail to parse
              // rather than crash the app on every keystroke.
              decimal * 100 < Decimal(Int.max)
        else { return nil }

        return Money(ringgit: decimal)
    }
}
