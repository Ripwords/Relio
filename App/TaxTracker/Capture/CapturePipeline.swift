import Foundation
import TaxKit
import TaxCapture

/// The one `DocumentPipeline` the app uses, and the copy for the one failure it throws.
@MainActor
enum CapturePipeline {

    enum Outcome {
        case read(ReceiptReading)
        /// Copy to show. The bytes could not be decoded at all; nothing was written.
        case failed(String)
    }

    /// Built once. The Vision requests and, where available, the on-device model are
    /// set up inside it, and there is no reason to pay for that per scan.
    private static let pipeline = DocumentPipeline.standard()

    static func read(_ input: CaptureInput, ruleSet: RuleSet?) async -> Outcome {
        do {
            return .read(try await pipeline.read(input, ruleSet: ruleSet))
        } catch {
            // Spec §6, first row: the existing strings, unchanged.
            if case .pdf = input { return .failed("That file could not be read. Try another.") }
            return .failed("That photo could not be read. Try another.")
        }
    }
}
