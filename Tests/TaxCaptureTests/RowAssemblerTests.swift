import Testing
@testable import TaxCapture

@Suite("Rejoining a row Vision split") struct RowAssemblerTests {

    static func fragment(_ text: String, left: Double, top: Double,
                         height: Double = 0.02, page: Int = 0,
                         confidence: Double = 1) -> TextFragment {
        TextFragment(text: text, page: page, left: left, top: top,
                     bottom: top + height, confidence: confidence)
    }

    @Test("a label and its amount on one row become one line, left to right")
    func joinsARow() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("18.40", left: 0.8, top: 0.501),
            Self.fragment("TOTAL", left: 0.1, top: 0.500),
        ])
        #expect(lines.map(\.text) == ["TOTAL 18.40"])
        #expect(lines.first?.top == 0.500)
    }

    @Test("rows further apart than half a line stay separate, top to bottom")
    func keepsRowsApart() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("CASH 20.00", left: 0.1, top: 0.53),
            Self.fragment("TOTAL 18.40", left: 0.1, top: 0.50),
        ])
        #expect(lines.map(\.text) == ["TOTAL 18.40", "CASH 20.00"])
    }

    @Test("a row is as sure as its least sure fragment")
    func confidenceIsTheMinimum() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("TOTAL", left: 0.1, top: 0.5, confidence: 0.9),
            Self.fragment("18.40", left: 0.8, top: 0.5, confidence: 0.4),
        ])
        #expect(lines.first?.confidence == 0.4)
    }

    @Test("pages are never merged, and come in order")
    func pagesStaySeparate() {
        let lines = RowAssembler.lines(from: [
            Self.fragment("PAGE TWO", left: 0.1, top: 0.1, page: 1),
            Self.fragment("PAGE ONE", left: 0.1, top: 0.1, page: 0),
        ])
        #expect(lines.map(\.text) == ["PAGE ONE", "PAGE TWO"])
        #expect(lines.map(\.page) == [0, 1])
    }
}
