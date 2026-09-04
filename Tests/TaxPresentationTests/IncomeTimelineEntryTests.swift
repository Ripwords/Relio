import Testing
import Foundation
import TaxKit
import TaxData
@testable import TaxPresentation

/// The income screen showed "1 Jan, RM 10,000 a month" above "1 Apr, RM 11,500 a month"
/// and left the reader to work out that the second was a raise. The timeline is the app's
/// best feature — income as a dated history rather than one figure a year — and it read as
/// two unrelated rows.
@Suite("Income timeline entries") struct IncomeTimelineEntryTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func rate(_ ringgit: Int, _ m: Int, shape: IncomeShape = .recurring) -> IncomeRecordDraft {
        IncomeRecordDraft(sourceID: UUID(), shape: shape,
                          amount: Money(ringgit: Decimal(ringgit)),
                          effectiveFrom: date(2025, m, 1))
    }

    @Test("the first rate is the starting rate, not a raise from nothing")
    func firstRateIsOpening() {
        let entries = IncomeTimelineEntry.build(from: [Self.rate(10_000, 1)])
        #expect(entries.map(\.change) == [.opening])
    }

    @Test("a higher rate is a raise, by the difference a month")
    func higherRateIsARaise() {
        let entries = IncomeTimelineEntry.build(from: [Self.rate(10_000, 1),
                                                       Self.rate(11_500, 4)])
        #expect(entries.map(\.change) == [.opening, .raise(by: Money(ringgit: 1_500))])
        #expect(entries.last?.change.delta == Money(ringgit: 1_500))
    }

    @Test("a lower rate is named as one rather than as a raise of a negative")
    func lowerRateIsACut() {
        let entries = IncomeTimelineEntry.build(from: [Self.rate(10_000, 1),
                                                       Self.rate(8_000, 7)])
        #expect(entries.last?.change == .cut(by: Money(ringgit: 2_000)))
    }

    /// Recordable, and it must not read as "Raise of RM 0.00".
    @Test("a restated rate is neither a raise nor a cut")
    func restatedRateIsUnchanged() {
        let entries = IncomeTimelineEntry.build(from: [Self.rate(10_000, 1),
                                                       Self.rate(10_000, 6)])
        #expect(entries.last?.change == .unchanged)
        #expect(entries.last?.change.delta == nil)
    }

    /// The one that would go wrong if every record were compared with the one before it:
    /// a bonus in March would make April's unchanged salary look like a collapse.
    @Test("a one-off does not make the next month's salary a cut")
    func oneOffDoesNotDisturbTheRate() {
        let entries = IncomeTimelineEntry.build(from: [
            Self.rate(10_000, 1),
            Self.rate(25_000, 3, shape: .oneOff),
            Self.rate(11_500, 4),
        ])
        #expect(entries.map(\.change) == [.opening,
                                          .oneOff,
                                          .raise(by: Money(ringgit: 1_500))])
    }

    /// Records arrive in whatever order the store returns them; the history is by date.
    @Test("the history is ordered by date whatever order the records arrive in")
    func orderIsByDate() {
        let entries = IncomeTimelineEntry.build(from: [Self.rate(11_500, 4),
                                                       Self.rate(10_000, 1)])
        #expect(entries.map(\.change) == [.opening, .raise(by: Money(ringgit: 1_500))])
    }

    @Test("every change has a title a person would use")
    func changesArePresentable() {
        let all: [IncomeTimelineEntry.Change] = [
            .opening, .raise(by: Money(ringgit: 1)), .cut(by: Money(ringgit: 1)),
            .unchanged, .oneOff,
        ]
        for change in all { #expect(!change.title.isEmpty) }
    }
}
