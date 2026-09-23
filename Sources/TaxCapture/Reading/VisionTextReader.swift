#if canImport(Vision)
import Foundation
import Vision

/// Spec §4: accurate recognition, English and both Chinese scripts, language correction
/// off. Malay is Latin script and correction "fixes" it into English — `JUMLAH` is not a
/// typo.
public struct VisionTextReader: TextReading {

    public init() {}

    public func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = [Locale.Language(identifier: "en-US"),
                                        Locale.Language(identifier: "zh-Hans"),
                                        Locale.Language(identifier: "zh-Hant")]
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: data)
        return observations.compactMap { observation in
            guard let best = observation.topCandidates(1).first else { return nil }
            // Vision's rectangle is normalised with its origin at the bottom left; rows
            // are rebuilt top to bottom, so flip it here, once.
            let box = observation.boundingBox.cgRect
            return TextFragment(text: best.string,
                                page: page,
                                left: Double(box.minX),
                                top: 1 - Double(box.maxY),
                                bottom: 1 - Double(box.minY),
                                confidence: Double(best.confidence))
        }
    }
}
#endif
