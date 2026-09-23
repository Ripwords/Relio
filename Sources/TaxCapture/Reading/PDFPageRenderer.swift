import CoreGraphics
import Foundation

/// PDF pages to pixels and pixels to PDF pages, with CoreGraphics alone, so it builds
/// wherever the package does.
enum PDFPageRenderer {

    static func document(_ data: Data) -> CGPDFDocument? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              document.numberOfPages > 0 else { return nil }
        return document
    }

    /// One page on white, `maxPixel` on its long edge. `pageIndex` is zero-based;
    /// CoreGraphics' own page numbers start at 1.
    ///
    /// A page's `/Rotate` is not applied. Till receipts and e-invoices are portrait and
    /// unrotated; if one turns up rotated it becomes a fixture and a fix.
    static func render(_ document: CGPDFDocument, pageIndex: Int, maxPixel: Int) -> CGImage? {
        guard let page = document.page(at: pageIndex + 1) else { return nil }
        let box = page.getBoxRect(.mediaBox)
        guard box.width > 0, box.height > 0 else { return nil }
        let scale = Double(maxPixel) / Double(max(box.width, box.height))
        let width = Int((Double(box.width) * scale).rounded())
        let height = Int((Double(box.height) * scale).rounded())
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        return context.makeImage()
    }

    /// Several scanned pages as one PDF, one image per page at its own size.
    static func pdf(from images: [CGImage]) -> Data? {
        guard !images.isEmpty else { return nil }
        let data = NSMutableData()
        var defaultBox = CGRect(x: 0, y: 0, width: images[0].width, height: images[0].height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &defaultBox, nil)
        else { return nil }
        for image in images {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }
}
