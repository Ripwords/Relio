import Testing
import Foundation
@testable import TaxData

@Suite("Wage month") struct WageMonthTests {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    @Test("months order by year first, so December precedes the January after it")
    func ordering() {
        #expect(WageMonth(year: 2025, month: 1) < WageMonth(year: 2025, month: 2))
        // Ordering on the month alone would put December 2024 after January 2025, and an
        // era boundary keyed to a wage month would then apply to the wrong months.
        #expect(WageMonth(year: 2024, month: 12) < WageMonth(year: 2025, month: 1))
        #expect(!(WageMonth(year: 2025, month: 1) < WageMonth(year: 2025, month: 1)))
    }

    @Test("a shuffled year sorts back into calendar order")
    func sorting() {
        let months = (1...12).map { WageMonth(year: 2025, month: $0) }
        #expect(months.shuffled().sorted() == months)
    }

    @Test("the month containing a date is the Kuala Lumpur month")
    func containingDate() {
        #expect(WageMonth(containing: Self.date(2025, 4, 15)) == WageMonth(year: 2025, month: 4))
        #expect(WageMonth(containing: Self.date(2024, 2, 29)) == WageMonth(year: 2024, month: 2))
    }

    @Test("a date near midnight is dated by Kuala Lumpur, not UTC")
    func zoneDecidesTheMonth() {
        // 2024-12-31 20:00 UTC is 2025-01-01 04:00 in KL. A device abroad must assess the
        // wage against the same month as the device at home, or a January wage becomes a
        // December one and lands in the wrong year of assessment.
        let newYearInKL = Date(timeIntervalSince1970: 1_735_675_200)
        #expect(WageMonth(containing: newYearInKL) == WageMonth(year: 2025, month: 1))
    }

    @Test("a wage month round-trips through Codable")
    func codableRoundTrip() throws {
        let april = WageMonth(year: 2025, month: 4)
        let data = try JSONEncoder().encode(april)
        #expect(try JSONDecoder().decode(WageMonth.self, from: data) == april)
    }
}
