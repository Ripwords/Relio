import Testing
import TaxKit
@testable import TaxCapture

/// A till prints money in more shapes than a person types it — `RM12.50`, `12.50 RM`,
/// `5.00-` for a discount — and prints plenty of numbers that are not money at all.
@Suite("Amounts on a till line") struct ReceiptAmountTests {

    @Test("the shapes a till prints", arguments: [
        ("TOTAL RM12.50", 1_250),
        ("TOTAL 12.50 RM", 1_250),
        ("GRAND TOTAL 1,234.56", 123_456),
        ("JUMLAH RM 7.00", 700),
        ("TOTAL: 0.90", 90),
    ])
    func readsTillShapes(line: String, sen: Int) {
        #expect(ReceiptAmount.amounts(in: line) == [Money(sen: sen)])
    }

    @Test("numbers that are not money", arguments: [
        "QTY 12.5",            // one decimal place
        "WEIGHT 12.500 KG",    // three
        "12.03.2025",          // a date
        "SST 6.00%",           // a rate
        "INV 2025/0001",
        "TEL 03-2345 6789",
        "",
    ])
    func ignoresNonMoney(line: String) {
        #expect(ReceiptAmount.amounts(in: line).isEmpty)
    }

    @Test("a discount printed with a trailing or leading minus is negative")
    func readsNegatives() {
        #expect(ReceiptAmount.amounts(in: "DISC 5.00-") == [Money(sen: -500)])
        #expect(ReceiptAmount.amounts(in: "DISCOUNT -RM 5.00") == [Money(sen: -500)])
        #expect(ReceiptAmount.amounts(in: "DISCOUNT -5.00") == [Money(sen: -500)])
    }

    /// A dash used as a separator is not a sign. "BOOK - 12.00" is a line item.
    @Test("a spaced dash is a separator, not a minus")
    func spacedDashIsNotASign() {
        #expect(ReceiptAmount.amounts(in: "BOOK - 12.00") == [Money(sen: 1_200)])
    }

    @Test("every amount on the line, in order")
    func readsSeveral() {
        #expect(ReceiptAmount.amounts(in: "2 x 3.50 7.00") == [Money(sen: 350), Money(sen: 700)])
    }

    /// `Money(sen:)` would take it, but multiplying a 20-digit ringgit figure by 100
    /// overflows `Int` and traps. A misread barcode must not crash the reader.
    @Test("an absurdly long number is skipped rather than crashing")
    func overflowIsSkipped() {
        #expect(ReceiptAmount.amounts(in: "12345678901234567890.00").isEmpty)
    }
}
