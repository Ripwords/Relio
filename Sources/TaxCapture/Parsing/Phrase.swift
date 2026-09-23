import Foundation

/// Text reduced to upper-case words, so a label matches as a whole word.
///
/// `" TOTAL "` is searched for in `" SUB TOTAL 18 40 "`, which is why `SUB-TOTAL` must be
/// excluded before `TOTAL` is looked for, and why `TOTAL` never matches inside `SUBTOTAL`.
/// Punctuation becomes a space: `SDN. BHD.` and `SDN BHD` are the same phrase.
struct Phrase {
    let padded: String

    init(_ text: String) {
        let mapped = String(text.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
        padded = " " + mapped.split(separator: " ").joined(separator: " ") + " "
    }

    var words: [Substring] { padded.split(separator: " ") }

    func contains(_ phrase: String) -> Bool { padded.contains(Phrase(phrase).padded) }

    func containsAny(_ phrases: [String]) -> Bool { phrases.contains(where: contains) }

    func first(of phrases: [String]) -> String? { phrases.first(where: contains) }
}
