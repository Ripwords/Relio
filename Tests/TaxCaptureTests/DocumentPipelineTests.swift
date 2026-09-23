#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

struct StubText: TextReading {
    enum Failure: Error { case failed }
    var lines: [String] = []
    var fails = false
    /// M1: pages whose OCR throws, so a test can prove the other pages' lines survive.
    var failingPages: Set<Int> = []
    func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        if fails || failingPages.contains(page) { throw Failure.failed }
        return lines.enumerated().map { index, text in
            let top = Double(index) / Double(max(lines.count, 1))
            return TextFragment(text: text, page: page, left: 0.05, top: top,
                                bottom: top + 0.5 / Double(max(lines.count, 1)), confidence: 1)
        }
    }
}

/// Counts its own calls so a test can single out one page to fail without depending on
/// image bytes, which `ImageNormaliser` re-encodes before a stub ever sees them.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        defer { count += 1 }
        return count
    }
}

struct StubBarcodes: BarcodeReading {
    var payloads: [String] = []
    var fails = false
    /// M2: 0-based call indices (this instance's first call is 0) that throw instead of
    /// returning `payloads`.
    var failingCalls: Set<Int> = []
    private let calls = CallCounter()
    func qrPayloads(inImage data: Data) async throws -> [String] {
        let index = calls.next()
        if fails || failingCalls.contains(index) { throw StubText.Failure.failed }
        return payloads
    }
}

struct StubPDFText: PDFTextReading {
    var lines: [String] = []
    func lines(inPDF data: Data) async throws -> [OCRLine] {
        lines.enumerated().map { OCRLine(text: $1, page: 0,
                                         top: Double($0) / Double(max(lines.count, 1))) }
    }
}

@Suite("The document pipeline") struct DocumentPipelineTests {

    static let now = Date(timeIntervalSince1970: 1_750_000_000)
    static let link = "https://myinvois.hasil.gov.my/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6V3K8H2M4T7W0"

    static func pipeline(text: StubText = StubText(lines: SampleReceipt.lines),
                         barcodes: StubBarcodes = StubBarcodes(),
                         pdfText: StubPDFText = StubPDFText()) -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(), text: text, pdfText: pdfText,
                         barcodes: barcodes, now: { Self.now })
    }

    static func rules() throws -> RuleSet { try BundledRuleSetLoader().ruleSet(for: 2025) }
    static func photo() throws -> CaptureInput { .image(try #require(SampleReceipt.jpeg())) }

    @Test("a readable photo gives its fields, its text and its reliefs")
    func readsAPhoto() async throws {
        let reading = try await Self.pipeline().read(try Self.photo(), ruleSet: try Self.rules())
        #expect(reading.total?.value == Money(sen: 7190))
        #expect(reading.total?.isConfirmed == true)
        #expect(reading.vendor?.value == "MPH BOOKSTORES SDN BHD")
        #expect(reading.date?.value == ReceiptDate.noon(2025, 3, 7))
        #expect(reading.date?.isConfirmed == false, "07/03 could be 3 July")
        #expect(reading.suggestedReliefs == [.lifestyle])
        #expect(reading.ocrText?.contains("TOTAL RM") == true)
        #expect(reading.document.uti == "public.jpeg")
        #expect(reading.document.thumbnail != nil)
        #expect(reading.failures.isEmpty)
        #expect(reading.couldNotRead == false)
    }

    @Test("bytes that cannot be decoded throw, and nothing else does")
    func undecodableThrows() async {
        await #expect(throws: CaptureError.unreadableImage) {
            try await Self.pipeline().read(.image(Data("x".utf8)), ruleSet: nil)
        }
    }

    @Test("no text found: an empty reading, with the file still there to attach")
    func noText() async throws {
        let reading = try await Self.pipeline(text: StubText(lines: []))
            .read(try Self.photo(), ruleSet: try Self.rules())
        #expect(reading.total == nil && reading.date == nil && reading.vendor == nil)
        #expect(reading.ocrText == nil)
        #expect(reading.suggestedReliefs.isEmpty)
        #expect(reading.couldNotRead)
        #expect(!reading.document.data.isEmpty)
    }

    @Test("OCR failing is soft: the failure is recorded and the file is kept")
    func textFailureIsSoft() async throws {
        let reading = try await Self.pipeline(text: StubText(fails: true))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.failures == [.text])
        #expect(reading.couldNotRead)
        #expect(!reading.document.data.isEmpty)
    }

    @Test("text with no total or date gives what it has and guesses nothing")
    func partialText() async throws {
        let reading = try await Self.pipeline(text: StubText(lines: ["PARKING TICKET", "LOT B2"]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.total == nil)
        #expect(reading.date == nil)
        #expect(reading.couldNotRead == false)
    }

    @Test("a MyInvois QR sets the e-invoice ID")
    func myInvoisQR() async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(payloads: [Self.link]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.eInvoiceUUID == "F9D425P6DS7D8IU")
    }

    @Test("any other QR is ignored and reading carries on",
          arguments: ["WIFI:S:Guest;T:WPA;P:x;;", "https://example.com/F9D425P6DS7D8IU/share/RZ6FQYX9J1G6"])
    func foreignQRIgnored(payload: String) async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(payloads: [payload]))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.eInvoiceUUID == nil)
        #expect(reading.total?.value == Money(sen: 7190))
        #expect(reading.failures.isEmpty)
    }

    @Test("the QR detector failing is soft")
    func barcodeFailureIsSoft() async throws {
        let reading = try await Self.pipeline(barcodes: StubBarcodes(fails: true))
            .read(try Self.photo(), ruleSet: nil)
        #expect(reading.failures == [.barcode])
        #expect(reading.total?.value == Money(sen: 7190))
    }

    /// M1. A single catch around the whole page loop used to set `lines = []`, so a scan's
    /// first page was thrown away along with its second.
    @Test("text: a page's lines are kept even when a later page throws")
    func textStageKeepsEarlierPagesOnALaterThrow() async throws {
        let page = try #require(SampleReceipt.jpeg())
        let reading = try await Self.pipeline(
            text: StubText(lines: ["PAGE LINE"], failingPages: [1])
        ).read(.scannedPages([page, page]), ruleSet: nil)
        #expect(reading.failures == [.text])
        #expect(reading.ocrText?.contains("PAGE LINE") == true, "page 0's lines are kept")
    }

    /// M2. One catch around the whole page loop aborted the rest of the scan, so a QR on
    /// page 2 was lost whenever page 1 threw.
    @Test("barcode: a later page's QR is still found when an earlier page throws")
    func barcodeStageFindsALaterPagesQRAfterAnEarlierThrow() async throws {
        let page = try #require(SampleReceipt.jpeg())
        let reading = try await Self.pipeline(
            barcodes: StubBarcodes(payloads: [Self.link], failingCalls: [0])
        ).read(.scannedPages([page, page]), ruleSet: nil)
        #expect(reading.failures == [.barcode])
        #expect(reading.eInvoiceUUID == "F9D425P6DS7D8IU")
    }

    @Test("a PDF from Files is read from its text layer, not OCR'd page by page")
    func pdfUsesTheTextLayer() async throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let reading = try await Self.pipeline(text: StubText(fails: true),
                                              pdfText: StubPDFText(lines: ["KLINIK MEDIVIRON",
                                                                           "TOTAL 77.50"]))
            .read(.pdf(pdf), ruleSet: try Self.rules())
        #expect(reading.total?.value == Money(sen: 7750))
        #expect(reading.failures.isEmpty, "the image OCR must not have been called")
        #expect(reading.suggestedReliefs == [.medicalSerious, .medicalCheckup])
        #expect(reading.document.data == pdf)
    }

    @Test("with no rulebook there are no relief suggestions, and nothing else changes")
    func noRuleSet() async throws {
        let reading = try await Self.pipeline().read(try Self.photo(), ruleSet: nil)
        #expect(reading.suggestedReliefs.isEmpty)
        #expect(reading.total?.value == Money(sen: 7190))
    }
}
#endif
