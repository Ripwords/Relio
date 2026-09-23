import Foundation

/// Where a value read off a receipt came from. Shown to nobody; kept so a test, and a
/// person debugging a bad read, can tell a labelled total from a guess.
public enum ReadingSource: Hashable, Sendable {
    /// Found next to a printed label, e.g. `.label("GRAND TOTAL")`.
    case label(String)
    /// From the MyInvois QR code.
    case qr
    /// Chosen by the on-device language model, and fact-checked against the text.
    case model
    /// A last resort with no label — the largest amount on the receipt, say.
    case heuristic
}

/// A value read off a receipt, with how sure the reader is of it.
public struct Reading<Value: Hashable & Sendable>: Hashable, Sendable {
    public var value: Value
    /// 0 to 1. Below `ReadingConfidence.confirmed` the editor shows it unconfirmed.
    public var confidence: Double
    public var source: ReadingSource

    public init(value: Value, confidence: Double, source: ReadingSource) {
        self.value = value
        self.confidence = confidence
        self.source = source
    }

    public var isConfirmed: Bool { confidence >= ReadingConfidence.confirmed }
}

public enum ReadingConfidence {
    /// At or above this, a field is prefilled as if the user had typed it.
    public static let confirmed: Double = 0.7
    /// Everything the language model contributes. Strictly below `confirmed`, so a
    /// model's answer is always shown for the user to check.
    public static let model: Double = 0.65
}
