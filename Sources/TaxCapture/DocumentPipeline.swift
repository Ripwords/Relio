import Foundation
import TaxKit

/// A stage that failed softly. Recorded so the editor can say "Relio couldn't read this
/// receipt" rather than showing silent blanks.
public enum ReadingStage: Hashable, Sendable {
    case barcode
    case text
    case model
}

/// Everything read from one receipt, and the file to keep.
///
/// Carries no content hash: `DocumentFileStore.write` computes that from
/// `document.data`, so there is one SHA-256 in the app rather than two that must agree.
public struct ReceiptReading: Hashable, Sendable {
    public var document: NormalisedDocument
    /// Every line, joined. Nil when no text was found at all.
    public var ocrText: String?
    public var eInvoiceUUID: String?
    public var total: Reading<Money>?
    public var date: Reading<Date>?
    public var vendor: Reading<String>?
    /// For the on-device model to choose among. Never shown.
    public var totalCandidates: [Money]
    /// At most three, best first, never selected for the user.
    public var suggestedReliefs: [ReliefCode]
    public var failures: Set<ReadingStage>

    public init(document: NormalisedDocument, ocrText: String? = nil,
                eInvoiceUUID: String? = nil, total: Reading<Money>? = nil,
                date: Reading<Date>? = nil, vendor: Reading<String>? = nil,
                totalCandidates: [Money] = [], suggestedReliefs: [ReliefCode] = [],
                failures: Set<ReadingStage> = []) {
        self.document = document
        self.ocrText = ocrText
        self.eInvoiceUUID = eInvoiceUUID
        self.total = total
        self.date = date
        self.vendor = vendor
        self.totalCandidates = totalCandidates
        self.suggestedReliefs = suggestedReliefs
        self.failures = failures
    }

    /// No text at all — whether OCR failed or found nothing. Spec §6's second row.
    public var couldNotRead: Bool { ocrText == nil }
}

/// Spec §3: normalise → barcode → text → extract. The file write, and so the hash, is the
/// caller's; this never touches the store.
///
/// Throws only when the input cannot be decoded at all. Every later stage fails softly
/// and the reading still carries the file, so the worst case is exactly today's: a file
/// attached and an editor to fill in by hand.
public actor DocumentPipeline {

    private let normaliser: any ImageNormalising
    private let text: any TextReading
    private let pdfText: any PDFTextReading
    private let barcodes: any BarcodeReading
    private let now: @Sendable () -> Date

    public init(normaliser: any ImageNormalising,
                text: any TextReading,
                pdfText: any PDFTextReading,
                barcodes: any BarcodeReading,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.normaliser = normaliser
        self.text = text
        self.pdfText = pdfText
        self.barcodes = barcodes
        self.now = now
    }

    #if canImport(Vision) && canImport(PDFKit) && canImport(ImageIO)
    /// The real adapters.
    public static func standard() -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(),
                         text: VisionTextReader(),
                         pdfText: PDFTextReader(ocr: VisionTextReader()),
                         barcodes: VisionBarcodeReader())
    }
    #endif

    public func read(_ input: CaptureInput, ruleSet: RuleSet?) async throws -> ReceiptReading {
        let document = try normaliser.normalise(input)
        var failures: Set<ReadingStage> = []

        var eInvoiceUUID: String?
        do {
            for image in document.pageImages where eInvoiceUUID == nil {
                eInvoiceUUID = try await barcodes.qrPayloads(inImage: image)
                    .lazy.compactMap(MyInvoisLink.init).first?.uuid
            }
        } catch {
            failures.insert(.barcode)
        }

        var lines: [OCRLine] = []
        do {
            switch document.textSource {
            case .pdfTextLayer:
                lines = try await pdfText.lines(inPDF: document.data)
            case .pageImages:
                for (page, image) in document.pageImages.enumerated() {
                    lines += RowAssembler.lines(from: try await text.fragments(inImage: image,
                                                                                page: page))
                }
            }
        } catch {
            failures.insert(.text)
            lines = []
        }

        let fields = ReceiptParser.parse(lines, now: now())
        let joined = lines.map(\.text).joined(separator: "\n")
        let ocrText = joined.isEmpty ? nil : joined
        let suggestions = ruleSet.map {
            ReliefSuggester.suggest(vendor: fields.vendor?.value, text: joined, in: $0)
        } ?? []

        return ReceiptReading(document: document,
                              ocrText: ocrText,
                              eInvoiceUUID: eInvoiceUUID,
                              total: fields.total,
                              date: fields.date,
                              vendor: fields.vendor,
                              totalCandidates: fields.totalCandidates,
                              suggestedReliefs: suggestions,
                              failures: failures)
    }
}
