#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// ImageIO, used the one way this package needs it.
enum ImageCoding {

    /// Decodes, applies the EXIF orientation and shrinks to `maxPixel` on the long edge,
    /// in one pass. Never enlarges.
    ///
    /// `CreateThumbnailWithTransform` is what applies the orientation. Without it the
    /// pixels come back as the sensor wrote them, and since `jpeg(_:)` writes no metadata
    /// the rotation would be lost rather than kept as a tag.
    static func decode(_ data: Data, maxPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// JPEG with no properties copied across — no EXIF, no GPS, no orientation tag.
    static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        encode(image, type: .jpeg,
               properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    static func png(_ image: CGImage) -> Data? {
        encode(image, type: .png, properties: [:])
    }

    private static func encode(_ image: CGImage, type: UTType,
                               properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
#endif
