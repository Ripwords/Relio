#if DEBUG && canImport(CoreText) && canImport(ImageIO)
import CoreGraphics
import CoreText
import Foundation
#if canImport(CoreImage)
import CoreImage
import CoreImage.CIFilterBuiltins
#endif

/// A receipt drawn from lines of text, with an optional QR under it. For tests and the
/// screenshot harness only — never compiled into a release build.
///
/// The date, 07/03/2025, is deliberately ambiguous (both numbers ≤ 12), so the harness
/// screenshot shows an unconfirmed field next to confirmed ones.
public enum SampleReceipt {

    public static let lines = [
        "MPH BOOKSTORES SDN BHD",
        "(197901006384)",
        "MID VALLEY MEGAMALL",
        "59200 KUALA LUMPUR",
        "TEL: 03-2938 3818",
        "TAX INVOICE",
        "DATE: 07/03/2025  14:22",
        "THE HOBBIT          49.90",
        "NOTEBOOK A5         22.00",
        "TOTAL RM            71.90",
        "CASH               100.00",
        "CHANGE              28.10",
    ]

    static let width = 1000.0
    static let margin = 60.0
    static let lineHeight = 56.0
    static let fontSize = 34.0
    static let qrSide = 320.0

    static func height(lineCount: Int, hasQR: Bool) -> Double {
        margin * 2 + Double(lineCount) * lineHeight + (hasQR ? qrSide + margin : 0)
    }

    public static func image(lines: [String] = lines, qr: String? = nil) -> CGImage? {
        let height = height(lineCount: lines.count, hasQR: qr != nil)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        draw(lines, qr: qr, in: context, height: height)
        return context.makeImage()
    }

    public static func jpeg(lines: [String] = lines, qr: String? = nil) -> Data? {
        image(lines: lines, qr: qr).flatMap { ImageCoding.jpeg($0, quality: 0.9) }
    }

    public static func png(lines: [String] = lines, qr: String? = nil) -> Data? {
        image(lines: lines, qr: qr).flatMap(ImageCoding.png)
    }

    /// - Parameter textLayer: true draws real text into the PDF, as a born-digital
    ///   e-invoice has; false draws the receipt as a picture, as a scan saved to PDF has.
    public static func pdf(lines: [String] = lines, textLayer: Bool, pages: Int = 1) -> Data? {
        guard textLayer else {
            guard let picture = image(lines: lines) else { return nil }
            return PDFPageRenderer.pdf(from: Array(repeating: picture, count: pages))
        }
        let data = NSMutableData()
        let height = height(lineCount: lines.count, hasQR: false)
        var box = CGRect(x: 0, y: 0, width: width, height: height)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil)
        else { return nil }
        for _ in 0..<pages {
            context.beginPage(mediaBox: &box)
            draw(lines, qr: nil, in: context, height: height)
            context.endPage()
        }
        context.closePDF()
        return data as Data
    }

    private static func draw(_ lines: [String], qr: String?, in context: CGContext,
                             height: Double) {
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.textMatrix = .identity
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorFromContextAttributeName as String): true,
            ])
            context.textPosition = CGPoint(x: margin,
                                           y: height - margin - Double(index + 1) * lineHeight)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        }
        #if canImport(CoreImage)
        if let qr, let code = qrImage(qr) {
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: margin, y: margin, width: qrSide, height: qrSide))
        }
        #endif
    }

    #if canImport(CoreImage)
    private static func qrImage(_ payload: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        return CIContext().createCGImage(scaled, from: scaled.extent)
    }
    #endif
}
#endif
