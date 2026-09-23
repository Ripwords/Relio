#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import TaxCapture

/// Spec §6, normalising. A receipt photo carries GPS in its EXIF and the store should not;
/// and because metadata is stripped, an iPhone's "rotate me" tag has to be *applied*, or
/// every portrait receipt is stored lying on its side.
@Suite("Normalising a captured receipt") struct ImageNormaliserTests {

    /// A solid image of the given size, encoded as JPEG with whatever properties are given.
    static func jpeg(width: Int, height: Int, properties: [CFString: Any] = [:]) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.2, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return data as Data
    }

    static func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    static func size(_ data: Data) -> (width: Int, height: Int) {
        let props = properties(data)
        return (props[kCGImagePropertyPixelWidth] as? Int ?? 0,
                props[kCGImagePropertyPixelHeight] as? Int ?? 0)
    }

    @Test("a photo tagged to be rotated is stored upright, with no orientation tag left")
    func orientationIsApplied() throws {
        // Stored 400 × 200 with orientation 6: the camera held portrait, the sensor wrote
        // landscape. Upright, that is 200 wide and 400 tall.
        let photo = Self.jpeg(width: 400, height: 200,
                              properties: [kCGImagePropertyOrientation: 6])
        let normalised = try ImageNormaliser().normalise(.image(photo))
        let size = Self.size(normalised.data)
        #expect(size.width == 200)
        #expect(size.height == 400)
        let orientation = Self.properties(normalised.data)[kCGImagePropertyOrientation] as? Int
        #expect(orientation == nil || orientation == 1)
    }

    @Test("location and every other metadata block are stripped")
    func metadataIsStripped() throws {
        let photo = Self.jpeg(width: 300, height: 300, properties: [
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 3.139,
                                            kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 101.687,
                                            kCGImagePropertyGPSLongitudeRef: "E"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "private"],
        ])
        #expect(Self.properties(photo)[kCGImagePropertyGPSDictionary] != nil,
                "the fixture itself must carry GPS, or this test proves nothing")
        let normalised = try ImageNormaliser().normalise(.image(photo))
        let props = Self.properties(normalised.data)
        #expect(props[kCGImagePropertyGPSDictionary] == nil)
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        #expect(exif?[kCGImagePropertyExifUserComment] == nil)
        #expect(normalised.uti == "public.jpeg")
        #expect(normalised.fileExtension == "jpg")
        #expect(normalised.textSource == .pageImages)
        #expect(normalised.pageImages == [normalised.data])
    }

    @Test("the long edge is capped at 2000 px, and a small photo is not enlarged")
    func longEdgeIsCapped() throws {
        let large = try ImageNormaliser().normalise(.image(Self.jpeg(width: 4000, height: 3000)))
        #expect(Self.size(large.data) == (2000, 1500))
        let small = try ImageNormaliser().normalise(.image(Self.jpeg(width: 640, height: 480)))
        #expect(Self.size(small.data) == (640, 480))
    }

    @Test("the thumbnail is 320 px on its long edge and under 30 KB")
    func thumbnailIsSmall() throws {
        let receipt = try #require(SampleReceipt.jpeg())
        let normalised = try ImageNormaliser().normalise(.image(receipt))
        let thumbnail = try #require(normalised.thumbnail)
        let size = Self.size(thumbnail)
        #expect(max(size.width, size.height) == 320)
        #expect(thumbnail.count < 30_000)
    }

    @Test("a PDF is stored byte for byte, with page one as its thumbnail")
    func pdfIsStoredUnchanged() throws {
        let pdf = try #require(SampleReceipt.pdf(textLayer: true))
        let normalised = try ImageNormaliser().normalise(.pdf(pdf))
        #expect(normalised.data == pdf)
        #expect(normalised.uti == "com.adobe.pdf")
        #expect(normalised.fileExtension == "pdf")
        #expect(normalised.textSource == .pdfTextLayer)
        let thumbnail = try #require(normalised.thumbnail)
        #expect(max(Self.size(thumbnail).width, Self.size(thumbnail).height) == 320)
        // Page one, rendered, so the pipeline can look for a QR on it.
        #expect(normalised.pageImages.count == 1)
    }

    @Test("one scanned page is a JPEG; several become one PDF, each page still readable")
    func scannedPages() throws {
        let page = try #require(SampleReceipt.jpeg())
        let one = try ImageNormaliser().normalise(.scannedPages([page]))
        #expect(one.uti == "public.jpeg")
        #expect(one.pageImages.count == 1)

        let three = try ImageNormaliser().normalise(.scannedPages([page, page, page]))
        #expect(three.uti == "com.adobe.pdf")
        #expect(three.textSource == .pageImages)
        #expect(three.pageImages.count == 3)
        let document = try #require(PDFPageRenderer.document(three.data))
        #expect(document.numberOfPages == 3)
    }

    @Test("bytes that are not an image or a PDF are refused")
    func garbageIsRefused() {
        let garbage = Data("not a receipt".utf8)
        #expect(throws: CaptureError.unreadableImage) {
            try ImageNormaliser().normalise(.image(garbage))
        }
        #expect(throws: CaptureError.unreadablePDF) {
            try ImageNormaliser().normalise(.pdf(garbage))
        }
        #expect(throws: CaptureError.unreadableImage) {
            try ImageNormaliser().normalise(.scannedPages([]))
        }
    }
}
#endif
