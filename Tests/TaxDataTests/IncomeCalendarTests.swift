import Testing
import Foundation
@testable import TaxData

@Suite("Income calendar") struct IncomeCalendarTests {

    /// Builds a Kuala Lumpur date from plain components, so every test below reads as a
    /// calendar date rather than an epoch number.
    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    @Test("a year's bounds are 1 January to 31 December in Kuala Lumpur")
    func yearBounds() {
        #expect(IncomeCalendar.year(of: IncomeCalendar.startOfYear(2025)) == 2025)
        #expect(IncomeCalendar.year(of: IncomeCalendar.endOfYear(2025)) == 2025)
        // One second before the year starts belongs to the previous year.
        #expect(IncomeCalendar.year(of: IncomeCalendar.startOfYear(2025).addingTimeInterval(-1)) == 2024)
    }

    @Test("a date near midnight is dated by Kuala Lumpur, not UTC")
    func zoneDecidesTheDate() {
        // 2024-12-31 20:00 UTC is 2025-01-01 04:00 in KL. A device abroad must agree with
        // the device at home about which YEAR a payment belongs to.
        let newYearInKL = Date(timeIntervalSince1970: 1_735_675_200)   // 2024-12-31 20:00 UTC
        #expect(IncomeCalendar.year(of: newYearInKL) == 2025)
    }

    @Test("month lengths are real, including February in a leap year")
    func monthLengths() {
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                          through: Self.date(2025, 4, 30)).first?.daysInMonth == 30)
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 2, 1),
                                          through: Self.date(2025, 2, 28)).first?.daysInMonth == 28)
        #expect(IncomeCalendar.monthSpans(from: Self.date(2024, 2, 1),
                                          through: Self.date(2024, 2, 29)).first?.daysInMonth == 29)
    }

    @Test("a whole month is one span of every day in it")
    func wholeMonth() {
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                              through: Self.date(2025, 4, 30))
        #expect(spans.count == 1)
        #expect(spans[0].days == 30)
        #expect(spans[0].daysInMonth == 30)
    }

    @Test("a partial month counts only its own days, both ends inclusive")
    func partialMonth() {
        // 1–14 April is fourteen days, not thirteen. Both ends are inclusive, which is the
        // off-by-one the whole design turns on.
        let opening = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 1),
                                                through: Self.date(2025, 4, 14))
        #expect(opening == [IncomeCalendar.MonthSpan(days: 14, daysInMonth: 30)])

        let closing = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                                through: Self.date(2025, 4, 30))
        #expect(closing == [IncomeCalendar.MonthSpan(days: 16, daysInMonth: 30)])
        #expect(opening[0].days + closing[0].days == 30)
    }

    @Test("a single day is one span of one day")
    func singleDay() {
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                              through: Self.date(2025, 4, 15))
        #expect(spans == [IncomeCalendar.MonthSpan(days: 1, daysInMonth: 30)])
    }

    @Test("a span across months splits per month with the right lengths")
    func acrossMonths() {
        // 20 Jan through 10 Mar: 12 days of January, all 28 of February, 10 of March.
        let spans = IncomeCalendar.monthSpans(from: Self.date(2025, 1, 20),
                                              through: Self.date(2025, 3, 10))
        #expect(spans == [IncomeCalendar.MonthSpan(days: 12, daysInMonth: 31),
                          IncomeCalendar.MonthSpan(days: 28, daysInMonth: 28),
                          IncomeCalendar.MonthSpan(days: 10, daysInMonth: 31)])
    }

    @Test("an inverted span is empty rather than negative")
    func invertedSpan() {
        // A rate that ends before it starts contributes nothing. Returning a negative day
        // count would subtract money from the year's income.
        #expect(IncomeCalendar.monthSpans(from: Self.date(2025, 4, 15),
                                          through: Self.date(2025, 4, 14)).isEmpty)
    }

    @Test("the day before a date is the previous calendar day")
    func dayBefore() {
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 4, 15)))
                == IncomeCalendar.startOfDay(Self.date(2025, 4, 14)))
        // Across a month boundary, and across a year boundary.
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 3, 1)))
                == IncomeCalendar.startOfDay(Self.date(2025, 2, 28)))
        #expect(IncomeCalendar.startOfDay(IncomeCalendar.dayBefore(Self.date(2025, 1, 1)))
                == IncomeCalendar.startOfDay(Self.date(2024, 12, 31)))
    }
}
