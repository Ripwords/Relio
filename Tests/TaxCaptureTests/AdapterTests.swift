#if canImport(Vision) && canImport(PDFKit)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

/// Counts calls and returns nothing, so a test can see how much OCR a reader asked for.
actor CountingTextReader: TextReading {
    private(set) var calls = 0
    nonisolated func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        await record()
        return []
    }
    private func record() { calls += 1 }
}

@Suite("Reading text and codes for real") struct AdapterTests {

    static let link = "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4T7W0"
    static let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("Vision reads the sample receipt, and the parser finds its total")
    func visionReadsAPhoto() async throws {
        let png = try #require(SampleReceipt.png())
        let lines = RowAssembler.lines(from: try await VisionTextReader().fragments(inImage: png, page: 0))
        let text = lines.map(\.text).joined(separator: "\n")
        #expect(text.contains("MPH BOOKSTORES"))
        #expect(text.contains("71.90"))
        #expect(ReceiptParser.parse(lines, now: Self.now).total?.value == Money(sen: 7190))
    }

    @Test("Vision finds the QR's payload")
    func qrPayloadIsRead() async throws {
        let png = try #require(SampleReceipt.png(qr: Self.link))
        #expect(try await VisionBarcodeReader().qrPayloads(inImage: png) == [Self.link])
    }

    @Test("a receipt with no QR has no payloads")
    func noQR() async throws {
        let png = try #require(SampleReceipt.png())
        #expect(try await VisionBarcodeReader().qrPayloads(inImage: png).isEmpty)
    }

    @Test("a born-digital PDF is read from its text layer, exactly, with no OCR")
    func textLayerFirst() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let ocr = CountingTextReader()
        let lines = try await PDFTextReader(ocr: ocr).lines(inPDF: pdf)
        let texts = lines.map { $0.text.split(separator: " ").joined(separator: " ") }
        #expect(texts.contains("TOTAL RM 71.90"))
        #expect(texts.first == "MPH BOOKSTORES SDN BHD")
        #expect(await ocr.calls == 0)
    }

    @Test("a page with no text layer is OCR'd")
    func imageOnlyPDFIsOCRd() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: false))
        let lines = try await PDFTextReader(ocr: VisionTextReader()).lines(inPDF: pdf)
        #expect(lines.map(\.text).joined(separator: "\n").contains("71.90"))
    }

    /// Review focus 5. A 40-page scanned statement must not mean 40 rounds of OCR.
    @Test("OCR stops after five image-only pages")
    func ocrFallbackStopsAtFivePages() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: false, pages: 40))
        let ocr = CountingTextReader()
        _ = try await PDFTextReader(ocr: ocr).lines(inPDF: pdf)
        #expect(await ocr.calls == PDFTextReader.ocrPageLimit)
        #expect(PDFTextReader.ocrPageLimit == 5)
    }

    @Test("bytes that are not a PDF are refused")
    func notAPDF() async {
        await #expect(throws: CaptureError.unreadablePDF) {
            try await PDFTextReader(ocr: CountingTextReader()).lines(inPDF: Data("x".utf8))
        }
    }
}
#endif
