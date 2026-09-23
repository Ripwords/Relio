import Foundation

/// What the user handed over, before anything has been done to it.
public enum CaptureInput: Hashable, Sendable {
    /// A photo from the library, or any file ImageIO can decode.
    case image(Data)
    /// A PDF from Files — usually born-digital, with a text layer.
    case pdf(Data)
    /// The document camera's pages, one image each, in order.
    case scannedPages([Data])
}

/// The input could not be decoded at all. The only failure the pipeline throws for;
/// everything after this point fails softly. Spec §6.
public enum CaptureError: Error, Hashable, Sendable {
    case unreadableImage
    case unreadablePDF
}

/// What gets stored, and what gets read.
public struct NormalisedDocument: Hashable, Sendable {

    /// Where the text comes from.
    public enum TextSource: Hashable, Sendable {
        /// OCR every image in `pageImages`.
        case pageImages
        /// A PDF from Files: its text layer first, OCR only for a page without one.
        case pdfTextLayer
    }

    /// The bytes to write to `DocumentFileStore`: a stripped JPEG, or a PDF.
    public var data: Data
    public var uti: String
    public var fileExtension: String
    /// 320 px long edge, JPEG. The only image bytes that would ever sync.
    public var thumbnail: Data?
    /// Upright JPEGs to read: every page of a photo or scan, or page one of a PDF file —
    /// rendered only so the pipeline can look for a MyInvois QR on it.
    public var pageImages: [Data]
    public var textSource: TextSource

    public init(data: Data, uti: String, fileExtension: String, thumbnail: Data?,
                pageImages: [Data], textSource: TextSource) {
        self.data = data
        self.uti = uti
        self.fileExtension = fileExtension
        self.thumbnail = thumbnail
        self.pageImages = pageImages
        self.textSource = textSource
    }
}
