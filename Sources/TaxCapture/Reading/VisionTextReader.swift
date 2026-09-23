#if canImport(Vision)
import Foundation
import Vision

/// Spec §4: accurate recognition, English and both Chinese scripts, language correction
/// off. Malay is Latin script and correction "fixes" it into English — `JUMLAH` is not a
/// typo.
///
/// I1: `.accurate` can fail outright, or hang, on the on-device compute path (an e5rt
/// asset/compile failure, seen on this Mac after 35-50 s). Waiting that long behind a
/// blocking overlay only to say "couldn't read" a perfectly readable receipt is worse
/// than falling through to `.fast`, which reads the same receipt in well under a second.
/// So `.accurate` is bounded by `accurateTimeout`; a throw or an expiry retries once with
/// `.fast` and English only. Only if `.fast` also fails does the page throw.
public struct VisionTextReader: TextReading {

    /// How long `.accurate` is given before the page falls through to `.fast`. Named and
    /// injectable so a test can drive the fallback without an 8 s wait.
    public static let defaultAccurateTimeout = Duration.seconds(8)

    /// The seam a test drives: "recognise this image at this level, in these languages."
    /// The real implementation is `recognizeWithVision`; tests substitute a stub that
    /// throws or hangs, without touching Vision at all.
    typealias Recognizer = @Sendable (_ data: Data, _ level: RecognizeTextRequest.RecognitionLevel,
                                      _ languages: [Locale.Language], _ page: Int) async throws -> [TextFragment]

    private let accurateTimeout: Duration
    private let recognize: Recognizer

    public init() {
        self.init(accurateTimeout: Self.defaultAccurateTimeout, recognize: Self.recognizeWithVision)
    }

    init(accurateTimeout: Duration, recognize: @escaping Recognizer) {
        self.accurateTimeout = accurateTimeout
        self.recognize = recognize
    }

    public func fragments(inImage data: Data, page: Int) async throws -> [TextFragment] {
        let accurateLanguages = [Locale.Language(identifier: "en-US"),
                                 Locale.Language(identifier: "zh-Hans"),
                                 Locale.Language(identifier: "zh-Hant")]
        let accurate = await Racing.firstToFinish(timeout: accurateTimeout, work: { [recognize] in
            try await recognize(data, .accurate, accurateLanguages, page)
        })
        if let lines = accurate {
            return lines
        }
        // `.accurate` threw or ran past its timeout — falls through to `.fast`, which is
        // not bounded: if it also fails, the page throws for real.
        return try await recognize(data, .fast, [Locale.Language(identifier: "en-US")], page)
    }

    /// The real Vision call, `usesLanguageCorrection` always off per spec §4.
    private static func recognizeWithVision(data: Data, level: RecognizeTextRequest.RecognitionLevel,
                                            languages: [Locale.Language],
                                            page: Int) async throws -> [TextFragment] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = languages
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
