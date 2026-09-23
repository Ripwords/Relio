import Foundation

public protocol ImageNormalising: Sendable {
    /// - Throws: `CaptureError` when the input cannot be decoded at all.
    func normalise(_ input: CaptureInput) throws -> NormalisedDocument
}

#if canImport(ImageIO)
import CoreGraphics

/// Spec §6: images to a 2000 px long edge, re-encoded as JPEG with every piece of
/// metadata dropped; PDFs stored unchanged. The hash is taken of *these* bytes, by
/// `DocumentFileStore.write`, so the same photo imported twice is still one file.
public struct ImageNormaliser: ImageNormalising {

    public static let maxPixel = 2000
    public static let thumbnailPixel = 320
    static let quality = 0.8
    static let thumbnailQuality = 0.6

    public init() {}

    public func normalise(_ input: CaptureInput) throws -> NormalisedDocument {
        switch input {
        case .image(let data):
            return try image(data)

        case .pdf(let data):
            guard let document = PDFPageRenderer.document(data) else {
                throw CaptureError.unreadablePDF
            }
            let pageOne = PDFPageRenderer.render(document, pageIndex: 0, maxPixel: Self.maxPixel)
                .flatMap { ImageCoding.jpeg($0, quality: Self.quality) }
            let thumbnail = PDFPageRenderer.render(document, pageIndex: 0,
                                                   maxPixel: Self.thumbnailPixel)
                .flatMap { ImageCoding.jpeg($0, quality: Self.thumbnailQuality) }
            return NormalisedDocument(data: data, uti: "com.adobe.pdf", fileExtension: "pdf",
                                      thumbnail: thumbnail,
                                      pageImages: pageOne.map { [$0] } ?? [],
                                      textSource: .pdfTextLayer)

        case .scannedPages(let pages):
            guard !pages.isEmpty else { throw CaptureError.unreadableImage }
            if pages.count == 1 { return try image(pages[0]) }

            var images: [CGImage] = []
            var jpegs: [Data] = []
            for page in pages {
                guard let decoded = ImageCoding.decode(page, maxPixel: Self.maxPixel),
                      let jpeg = ImageCoding.jpeg(decoded, quality: Self.quality)
                else { throw CaptureError.unreadableImage }
                images.append(decoded)
                jpegs.append(jpeg)
            }
            guard let pdf = PDFPageRenderer.pdf(from: images) else {
                throw CaptureError.unreadableImage
            }
            return NormalisedDocument(data: pdf, uti: "com.adobe.pdf", fileExtension: "pdf",
                                      thumbnail: Self.thumbnail(of: jpegs[0]),
                                      pageImages: jpegs, textSource: .pageImages)
        }
    }

    private func image(_ data: Data) throws -> NormalisedDocument {
        guard let decoded = ImageCoding.decode(data, maxPixel: Self.maxPixel),
              let jpeg = ImageCoding.jpeg(decoded, quality: Self.quality)
        else { throw CaptureError.unreadableImage }
        return NormalisedDocument(data: jpeg, uti: "public.jpeg", fileExtension: "jpg",
                                  thumbnail: Self.thumbnail(of: jpeg),
                                  pageImages: [jpeg], textSource: .pageImages)
    }

    static func thumbnail(of data: Data) -> Data? {
        ImageCoding.decode(data, maxPixel: thumbnailPixel)
            .flatMap { ImageCoding.jpeg($0, quality: thumbnailQuality) }
    }
}
#endif
