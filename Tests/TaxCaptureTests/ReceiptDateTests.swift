import Testing
import Foundation
@testable import TaxCapture

@Suite("Dates on a receipt line") struct ReceiptDateTests {

    /// 15 June 2025, the suite-wide test clock.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    static func day(_ y: Int, _ m: Int, _ d: Int) -> Date { ReceiptDate.noon(y, m, d)! }

    @Test("the formats Malaysian tills print", arguments: [
        ("DATE: 14/03/2025", 2025, 3, 14),
        ("14/03/25 13:02", 2025, 3, 14),
        ("14-03-2025", 2025, 3, 14),
        ("14.03.2025", 2025, 3, 14),
        ("2025-03-14", 2025, 3, 14),
        ("2025/03/14", 2025, 3, 14),
        ("14 Mar 2025", 2025, 3, 14),
        ("07 Mac 2025", 2025, 3, 7),
        ("28-OGOS-2024", 2024, 8, 28),
        ("3 Mei 2025", 2025, 5, 3),
        ("1-Okt-24", 2024, 10, 1),
        ("25 Dis 2024", 2024, 12, 25),
        ("5 June, 2025", 2025, 6, 5),
    ])
    func readsFormats(line: String, y: Int, m: Int, d: Int) {
        let found = ReceiptDate.dates(in: line, now: Self.now)
        #expect(found.map(\.date) == [Self.day(y, m, d)])
    }

    @Test("two dates on one line come back in the order they are printed, not by format")
    func ordersByTextualPosition() {
        let found = ReceiptDate.dates(in: "12 Mar 2025 PAID 14/03/2025", now: Self.now)
        #expect(found.map(\.date) == [Self.day(2025, 3, 12), Self.day(2025, 3, 14)])
    }

    @Test("an impossible date is not a date")
    func rejectsImpossible() {
        #expect(ReceiptDate.dates(in: "31/02/2025", now: Self.now).isEmpty)
        #expect(ReceiptDate.dates(in: "00/03/2025", now: Self.now).isEmpty)
    }

    @Test("a date in the future is not a candidate")
    func rejectsFuture() {
        #expect(ReceiptDate.dates(in: "20/07/2025", now: Self.now).isEmpty)
    }

    @Test("today is a candidate")
    func acceptsToday() {
        #expect(ReceiptDate.dates(in: "15/06/2025", now: Self.now).map(\.date)
                == [Self.day(2025, 6, 15)])
    }

    @Test("more than seven years back is not a candidate")
    func rejectsAncient() {
        #expect(ReceiptDate.dates(in: "14/03/2017", now: Self.now).isEmpty)
        #expect(ReceiptDate.dates(in: "16/06/2018", now: Self.now).count == 1)
    }

    @Test("day and month both twelve or under, and different, is ambiguous")
    func flagsAmbiguous() {
        #expect(ReceiptDate.dates(in: "04/05/2025", now: Self.now).first?.ambiguous == true)
        #expect(ReceiptDate.dates(in: "05/05/2025", now: Self.now).first?.ambiguous == false)
        #expect(ReceiptDate.dates(in: "14/03/2025", now: Self.now).first?.ambiguous == false)
        #expect(ReceiptDate.dates(in: "14 Mar 2025", now: Self.now).first?.ambiguous == false)
    }

    @Test("numbers that are not dates", arguments: [
        "TEL 03-2345 6789",
        "INV 2025/0001",
        "TOTAL 12.50",
        "SST ID W10-1808-32000123",
    ])
    func ignoresNonDates(line: String) {
        #expect(ReceiptDate.dates(in: line, now: Self.now).isEmpty)
    }
}
