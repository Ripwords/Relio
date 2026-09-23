import Foundation
import TaxKit

/// Money as a till prints it.
///
/// Not `MoneyParsing`, which lives in `TaxPresentation` and reads what a person types.
/// A till prints `RM12.50`, `12.50 RM` and `5.00-`, and prints dates, rates and weights
/// that look like amounts. Exactly two decimals are required: `12.5` and `12.500` are a
/// quantity and a weight far more often than they are money.
public enum ReceiptAmount {

    public static func amounts(in line: String) -> [Money] {
        // Swift's Regex has no lookbehind, so "not preceded by a digit, `.` or `,`" is
        // checked by hand below. The lookahead refuses a third decimal, a following
        // `.5`/`,5` (a date or a longer number) and a percentage.
        let pattern = /(\d{1,3}(?:,\d{3})+|\d+)\.(\d{2})(?!\d|[.,]\d|%)/
        var result: [Money] = []
        for match in line.matches(of: pattern) {
            let range = match.range
            if range.lowerBound > line.startIndex {
                let before = line[line.index(before: range.lowerBound)]
                if before.isNumber || before == "." || before == "," { continue }
            }
            // `Int(_:)` refuses non-ASCII digits, which `\d` admits. Refusing is right.
            guard let ringgit = Int(match.output.1.replacingOccurrences(of: ",", with: "")),
                  let sen = Int(match.output.2) else { continue }
            let (hundreds, overflowed) = ringgit.multipliedReportingOverflow(by: 100)
            guard !overflowed else { continue }
            let (total, overflowedAgain) = hundreds.addingReportingOverflow(sen)
            guard !overflowedAgain else { continue }
            result.append(Money(sen: isNegative(range, in: line) ? -total : total))
        }
        return result
    }

    /// `-5.00`, `-RM5.00`, `-RM 5.00` and `5.00-` are negative. `BOOK - 12.00` is not:
    /// the dash must touch the number or its `RM`.
    private static func isNegative(_ range: Range<String.Index>, in line: String) -> Bool {
        if line[range.upperBound...].first == "-" { return true }
        var head = line[..<range.lowerBound]
        let trimmed = head.reversed().drop(while: { $0 == " " })
        let trimmedHead = String(trimmed.reversed())
        if trimmedHead.uppercased().hasSuffix("RM") {
            head = Substring(trimmedHead.dropLast(2))
        }
        return head.last == "-"
    }
}
