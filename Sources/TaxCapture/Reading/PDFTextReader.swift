#if canImport(PDFKit) && canImport(ImageIO)
import Foundation
import PDFKit

/// Spec §4: the text layer first — a born-digital e-invoice has one and it is exact —
/// and OCR only for a page without one.
///
/// Lines come from PDFKit's per-line selections with their positions, not from
/// `page.string`, so a label and its amount drawn far apart on one row are rejoined by
/// `RowAssembler` the same way Vision's fragments are.
public struct PDFTextReader: PDFTextReading {

    /// A long image-only PDF — a scanned statement — is not worth forty rounds of OCR for
    /// a receipt's three fields, which are on the first page anyway.
    public static let ocrPageLimit = 5

    private let ocr: any TextReading

    public init(ocr: any TextReading) {
        self.ocr = ocr
    }

    public func lines(inPDF data: Data) async throws -> [OCRLine] {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw CaptureError.unreadablePDF
        }
        var lines: [OCRLine] = []
        var pagesOCRd = 0
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            let layer = Self.textLayer(of: page, index: index)
            if !layer.isEmpty {
                lines += RowAssembler.lines(from: layer)
                continue
            }
            guard pagesOCRd < Self.ocrPageLimit else { continue }
            pagesOCRd += 1
            guard let rendered = PDFPageRenderer.document(data)
                    .flatMap({ PDFPageRenderer.render($0, pageIndex: index,
                                                      maxPixel: ImageNormaliser.maxPixel) }),
                  let jpeg = ImageCoding.jpeg(rendered, quality: 0.8) else { continue }
            lines += RowAssembler.lines(from: try await ocr.fragments(inImage: jpeg, page: index))
        }
        return lines
    }

    private static func textLayer(of page: PDFPage, index: Int) -> [TextFragment] {
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0,
              let selections = page.selection(for: bounds)?.selectionsByLine() else { return [] }
        return selections.compactMap { selection in
            guard let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            let rect = selection.bounds(for: page)
            // PDF space has its origin at the bottom left, like Vision's.
            return TextFragment(text: text,
                                page: index,
                                left: Double((rect.minX - bounds.minX) / bounds.width),
                                top: 1 - Double((rect.maxY - bounds.minY) / bounds.height),
                                bottom: 1 - Double((rect.minY - bounds.minY) / bounds.height),
                                confidence: 1)
        }
    }
}
#endif
