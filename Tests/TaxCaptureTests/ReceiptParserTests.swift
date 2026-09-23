import Testing
import Foundation
import TaxKit
@testable import TaxCapture

struct ReceiptFixture: Decodable {
    struct Expectation: Decodable {
        var total: String?
        var totalConfirmed: Bool?
        var date: String?
        var dateConfirmed: Bool?
        var vendor: String?
        var vendorConfirmed: Bool?
    }

    var lines: [String]
    var expect: Expectation

    static let names = [
        "supermarket", "pharmacy", "bookshop", "clinic", "bm-only", "chinese-vendor",
        "rounding", "service-charge", "unlabelled-total", "no-total",
        "conflicting-totals", "ambiguous-date", "future-date",
    ]

    static func load(_ name: String) throws -> ReceiptFixture {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures/receipts"))
        return try JSONDecoder().decode(ReceiptFixture.self, from: Data(contentsOf: url))
    }

    var ocrLines: [OCRLine] {
        lines.enumerated().map { index, text in
            OCRLine(text: text, page: 0, top: Double(index) / Double(lines.count), confidence: 1)
        }
    }
}

@Suite("Reading a receipt's fields") struct ReceiptParserTests {

    /// 15 June 2025, the suite-wide test clock.
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    static func money(_ text: String) -> Money? { ReceiptAmount.amounts(in: text).first }

    static func date(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        return ReceiptDate.noon(parts[0], parts[1], parts[2])
    }

    @Test("each receipt in the corpus reads as expected", arguments: ReceiptFixture.names)
    func corpus(name: String) throws {
        let fixture = try ReceiptFixture.load(name)
        let fields = ReceiptParser.parse(fixture.ocrLines, now: Self.now)
        let expect = fixture.expect

        #expect(fields.total?.value == expect.total.flatMap(Self.money), "total")
        #expect(fields.total?.isConfirmed == expect.totalConfirmed, "total band")
        #expect(fields.date?.value == expect.date.flatMap(Self.date), "date")
        #expect(fields.date?.isConfirmed == expect.dateConfirmed, "date band")
        #expect(fields.vendor?.value == expect.vendor, "vendor")
        #expect(fields.vendor?.isConfirmed == expect.vendorConfirmed, "vendor band")
    }

    @Test("a label alone on its line takes the amount on the next")
    func labelOnItsOwnLine() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL"), OCRLine(text: "RM 18.40")],
                                         now: Self.now)
        #expect(fields.total?.value == Money(sen: 1_840))
        #expect(fields.total?.source == .label("TOTAL"))
    }

    @Test("a grand total beats a total, whichever comes first")
    func rankOneWins() {
        let fields = ReceiptParser.parse([OCRLine(text: "GRAND TOTAL 90.10"),
                                          OCRLine(text: "TOTAL 85.00")], now: Self.now)
        #expect(fields.total?.value == Money(sen: 9_010))
        #expect(fields.total?.confidence == 0.95)
    }

    /// The recogniser was unsure of the very characters that make up the figure.
    @Test("a total read with low recogniser confidence is not confirmed")
    func lowLineConfidenceCaps() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL 18.40", confidence: 0.4)],
                                         now: Self.now)
        #expect(fields.total?.value == Money(sen: 1_840))
        #expect(fields.total?.isConfirmed == false)
    }

    @Test("two different dates on one receipt leave the chosen one unconfirmed")
    func severalDatesCap() {
        let fields = ReceiptParser.parse([OCRLine(text: "DATE: 14/03/2025"),
                                          OCRLine(text: "ORDER 12/03/2025")], now: Self.now)
        #expect(fields.date?.value == ReceiptDate.noon(2025, 3, 14))
        #expect(fields.date?.isConfirmed == false)
    }

    @Test("the model is offered every labelled total, best first, once each")
    func candidatesForTheModel() {
        let fields = ReceiptParser.parse([OCRLine(text: "TOTAL 45.00"),
                                          OCRLine(text: "TOTAL 54.00"),
                                          OCRLine(text: "TOTAL 54.00")], now: Self.now)
        #expect(fields.totalCandidates == [Money(sen: 5_400), Money(sen: 4_500)])
    }

    @Test("nothing to read reads as nothing")
    func emptyInput() {
        #expect(ReceiptParser.parse([], now: Self.now) == ReceiptFields())
    }
}
