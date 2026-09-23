import Foundation

/// One printed row of a receipt, as the recogniser read it.
public struct OCRLine: Hashable, Sendable, Codable {
    public var text: String
    /// Zero-based page. Only page 0 is searched for the vendor.
    public var page: Int
    /// Distance from the top of the page, 0 to 1. Vision reports a bottom-left origin;
    /// the adapter flips it so "top third" reads as `top < 1/3`.
    public var top: Double
    /// The recogniser's own confidence, 0 to 1. The lowest fragment's, for a row that
    /// was assembled from several.
    public var confidence: Double

    public init(text: String, page: Int = 0, top: Double = 0, confidence: Double = 1) {
        self.text = text
        self.page = page
        self.top = top
        self.confidence = confidence
    }
}
