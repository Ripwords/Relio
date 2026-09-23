import Foundation
import Synchronization
import TaxKit

/// A relief the model may name, with the name it goes by.
public struct ReliefChoice: Hashable, Sendable {
    public var code: ReliefCode
    public var name: String

    public init(code: ReliefCode, name: String) {
        self.code = code
        self.name = name
    }
}

/// Everything the model is shown. It chooses among these; it never supplies a number.
public struct ReceiptModelQuestion: Hashable, Sendable {
    public var ocrText: String
    /// Best first, as the parser ranked them. The model answers with an index.
    public var totalCandidates: [Money]
    public var reliefs: [ReliefChoice]

    public init(ocrText: String, totalCandidates: [Money], reliefs: [ReliefChoice]) {
        self.ocrText = ocrText
        self.totalCandidates = totalCandidates
        self.reliefs = reliefs
    }

    public var prompt: String {
        let candidates = totalCandidates.enumerated()
            .map { "\($0.offset): \($0.element.formatted())" }
            .joined(separator: "\n")
        let codes = reliefs.map { "\($0.code.rawValue): \($0.name)" }.joined(separator: "\n")
        return """
        Receipt text:
        \(ocrText)

        Total candidates:
        \(candidates.isEmpty ? "(none)" : candidates)

        Reliefs:
        \(codes)
        """
    }
}

/// What the model said, unchecked.
public struct ReceiptModelAnswer: Hashable, Sendable {
    public var vendor: String?
    public var totalCandidate: Int?
    public var relief: String?

    public init(vendor: String?, totalCandidate: Int?, relief: String?) {
        self.vendor = vendor
        self.totalCandidate = totalCandidate
        self.relief = relief
    }
}

/// An on-device language model. Optional, and never trusted: see `ReceiptModelCheck`.
public protocol ReceiptModel: Sendable {
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer
}

/// Spec §4, "The on-device model": what it may be asked, how long it is waited for, and
/// which parts of its answer survive.
public enum ReceiptModelCheck {

    /// Nil when there is no text: there is nothing to ask about.
    public static func question(for reading: ReceiptReading,
                                in ruleSet: RuleSet) -> ReceiptModelQuestion? {
        guard let text = reading.ocrText else { return nil }
        // The same filter the suggester applies: an automatic relief is never logged.
        let reliefs = ruleSet.allReliefs
            .filter { !$0.automatic }
            .map { ReliefChoice(code: $0.code, name: $0.name) }
        return ReceiptModelQuestion(ocrText: text, totalCandidates: reading.totalCandidates,
                                    reliefs: reliefs)
    }

    /// The answer, or nil if the model threw or took longer than `timeout`.
    ///
    /// Returns at the timeout even if the model ignores cancellation. A task group would
    /// wait for its child, so this races the two with a continuation that only the first
    /// to finish may resume.
    public static func answer(from model: any ReceiptModel, to question: ReceiptModelQuestion,
                              within timeout: Duration) async -> ReceiptModelAnswer? {
        let once = Once()
        return await withCheckedContinuation { continuation in
            let work = Task {
                let answer = try? await model.answer(question)
                once.run { continuation.resume(returning: answer) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                work.cancel()
                once.run { continuation.resume(returning: nil) }
            }
        }
    }

    /// Keeps what passes a check and silently drops the rest. Everything kept is at
    /// `ReadingConfidence.model`, below confirmed, so it is always marked for the user.
    public static func apply(_ answer: ReceiptModelAnswer, to reading: ReceiptReading,
                             question: ReceiptModelQuestion) -> ReceiptReading {
        var result = reading

        if let index = answer.totalCandidate,
           question.totalCandidates.indices.contains(index),
           !(reading.total?.isConfirmed ?? false) {
            result.total = Reading(value: question.totalCandidates[index],
                                   confidence: ReadingConfidence.model, source: .model)
        }

        if let vendor = answer.vendor,
           !collapsed(vendor).isEmpty,
           collapsed(question.ocrText).contains(collapsed(vendor)),
           (reading.vendor?.confidence ?? 0) < ReadingConfidence.confirmed {
            result.vendor = Reading(value: vendor.trimmingCharacters(in: .whitespaces),
                                    confidence: ReadingConfidence.model, source: .model)
        }

        if let named = answer.relief,
           let choice = question.reliefs.first(where: { $0.code.rawValue == named }) {
            result.suggestedReliefs = Array(([choice.code]
                + reading.suggestedReliefs.filter { $0 != choice.code }).prefix(3))
        }

        return result
    }

    /// Upper-cased, with every run of whitespace — newlines included — one space.
    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
    }
}

/// Runs its body once, whichever caller gets there first.
private final class Once: Sendable {
    private let done = Mutex(false)

    func run(_ body: () -> Void) {
        let first = done.withLock { done in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
