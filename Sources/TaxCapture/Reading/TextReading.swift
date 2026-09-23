import Foundation

/// OCR over one upright image. Behind a protocol so the pipeline's tests can hand it
/// whatever text they need without Vision.
public protocol TextReading: Sendable {
    func fragments(inImage data: Data, page: Int) async throws -> [TextFragment]
}

/// QR payloads found in one image, as strings. Only QR — a till's barcode is a product
/// code and says nothing about the claim.
public protocol BarcodeReading: Sendable {
    func qrPayloads(inImage data: Data) async throws -> [String]
}

/// A PDF's lines, from its text layer where it has one.
public protocol PDFTextReading: Sendable {
    func lines(inPDF data: Data) async throws -> [OCRLine]
}
