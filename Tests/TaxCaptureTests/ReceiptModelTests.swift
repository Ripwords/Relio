#if canImport(ImageIO) && canImport(CoreText)
import Testing
import Foundation
import TaxKit
@testable import TaxCapture

/// Answers whatever it was built with, and records that it was asked.
struct StubModel: ReceiptModel {
    enum Failure: Error { case refused }
    var reply = ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: nil)
    var fails = false
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        if fails { throw Failure.refused }
        return reply
    }
}

/// Never answers, and ignores cancellation — the worst case the timeout must survive.
struct SilentModel: ReceiptModel {
    func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
        return ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: nil)
    }
}

@Suite("The on-device model, fact-checked") struct ReceiptModelTests {

    static let text = "KEDAI  BUKU aneka\nTOTAL 45.00\nTOTAL 54.00"

    static func question(candidates: [Money] = [Money(sen: 5_400), Money(sen: 4_500)])
        -> ReceiptModelQuestion {
        ReceiptModelQuestion(ocrText: text, totalCandidates: candidates,
                             reliefs: [ReliefChoice(code: .lifestyle, name: "Lifestyle"),
                                       ReliefChoice(code: .lifestyleSports, name: "Sports")])
    }

    /// A reading as the parser leaves a receipt with two disagreeing totals and a
    /// vendor it was not sure of.
    static func unsure() -> ReceiptReading {
        ReceiptReading(
            document: NormalisedDocument(data: Data(), uti: "public.jpeg", fileExtension: "jpg",
                                         thumbnail: nil, pageImages: [], textSource: .pageImages),
            ocrText: text,
            total: Reading(value: Money(sen: 5_400), confidence: 0.5, source: .label("TOTAL")),
            vendor: Reading(value: "KEDAI BUKU", confidence: 0.6, source: .heuristic),
            totalCandidates: [Money(sen: 5_400), Money(sen: 4_500)],
            suggestedReliefs: [.lifestyleSports])
    }

    static func apply(_ answer: ReceiptModelAnswer, to reading: ReceiptReading = unsure())
        -> ReceiptReading {
        ReceiptModelCheck.apply(answer, to: reading, question: question())
    }

    @Test("a vendor printed on the receipt is taken, at model confidence")
    func vendorInTextIsTaken() {
        let result = Self.apply(ReceiptModelAnswer(vendor: "Kedai Buku Aneka",
                                                   totalCandidate: nil, relief: nil))
        #expect(result.vendor == Reading(value: "Kedai Buku Aneka",
                                         confidence: ReadingConfidence.model, source: .model))
    }

    /// Spec success criterion 3's sibling for text: a name the model made up never
    /// reaches the editor.
    @Test("a vendor that is not on the receipt is discarded",
          arguments: ["Kinokuniya", "", "   "])
    func vendorNotInTextIsDiscarded(vendor: String) {
        let result = Self.apply(ReceiptModelAnswer(vendor: vendor, totalCandidate: nil, relief: nil))
        #expect(result.vendor?.value == "KEDAI BUKU")
    }

    @Test("a vendor the parser was sure of is kept")
    func confidentVendorIsKept() {
        var reading = Self.unsure()
        reading.vendor = Reading(value: "KEDAI BUKU", confidence: 0.9, source: .heuristic)
        let result = Self.apply(ReceiptModelAnswer(vendor: "Kedai Buku Aneka",
                                                   totalCandidate: nil, relief: nil), to: reading)
        #expect(result.vendor?.value == "KEDAI BUKU")
    }

    @Test("an in-range candidate chooses between disagreeing totals")
    func candidateChoosesTheTotal() {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: 1, relief: nil))
        #expect(result.total == Reading(value: Money(sen: 4_500),
                                        confidence: ReadingConfidence.model, source: .model))
    }

    /// Spec success criterion 3. The model only ever names an index, so the only way it
    /// could introduce a number is an index that is not one; that is discarded.
    @Test("an out-of-range candidate is discarded", arguments: [-1, 2, 99])
    func outOfRangeCandidateIsDiscarded(index: Int) {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: index, relief: nil))
        #expect(result.total?.value == Money(sen: 5_400))
        #expect(result.total?.source == .label("TOTAL"))
    }

    @Test("a total the parser was sure of is not second-guessed")
    func confidentTotalIsKept() {
        var reading = Self.unsure()
        reading.total = Reading(value: Money(sen: 5_400), confidence: 0.95, source: .label("TOTAL"))
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: 1, relief: nil),
                                to: reading)
        #expect(result.total?.value == Money(sen: 5_400))
    }

    @Test("a relief it was offered moves to the front; three at most")
    func offeredReliefLeads() {
        var reading = Self.unsure()
        reading.suggestedReliefs = [.lifestyleSports, .medicalSerious, .medicalCheckup]
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: nil,
                                                   relief: "LIFESTYLE"), to: reading)
        #expect(result.suggestedReliefs == [.lifestyle, .lifestyleSports, .medicalSerious])
    }

    @Test("a relief it was not offered is discarded", arguments: ["SSPN", "MADE_UP", ""])
    func unofferedReliefIsDiscarded(code: String) {
        let result = Self.apply(ReceiptModelAnswer(vendor: nil, totalCandidate: nil, relief: code))
        #expect(result.suggestedReliefs == [.lifestyleSports])
    }

    @Test("nothing the model supplies is ever confirmed")
    func modelNeverConfirms() {
        let result = Self.apply(ReceiptModelAnswer(vendor: "KEDAI BUKU ANEKA",
                                                   totalCandidate: 0, relief: nil))
        #expect(result.vendor?.isConfirmed == false)
        #expect(result.total?.isConfirmed == false)
    }

    @Test("a model that never answers is abandoned at the timeout")
    func silentModelTimesOut() async {
        let started = ContinuousClock.now
        let answer = await ReceiptModelCheck.answer(from: SilentModel(), to: Self.question(),
                                                    within: .milliseconds(100))
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("a model that throws gives no answer")
    func failingModelGivesNothing() async {
        #expect(await ReceiptModelCheck.answer(from: StubModel(fails: true), to: Self.question(),
                                               within: .seconds(1)) == nil)
    }

    /// M3. Cancelling the caller must not leave the race to sit out the full timeout: the
    /// race is wrapped in `withTaskCancellationHandler`, so cancellation resolves it
    /// immediately rather than waiting for `SilentModel`, which ignores cancellation.
    @Test("a cancelled caller returns promptly, well under the timeout")
    func cancelledCallerReturnsPromptly() async {
        let task = Task<ReceiptModelAnswer?, Never> {
            await ReceiptModelCheck.answer(from: SilentModel(), to: Self.question(),
                                           within: .seconds(30))
        }
        try? await Task.sleep(for: .milliseconds(10))
        let started = ContinuousClock.now
        task.cancel()
        let answer = await task.value
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    /// A caller already cancelled when the race starts: the cancellation handler runs
    /// before the continuation exists, and the race must still resolve, not hang.
    @Test("a caller cancelled before the race starts returns promptly",
          .timeLimit(.minutes(1)))
    func alreadyCancelledCallerReturnsPromptly() async {
        let task = Task<ReceiptModelAnswer?, Never> {
            withUnsafeCurrentTask { $0?.cancel() }
            return await ReceiptModelCheck.answer(from: SilentModel(), to: Self.question(),
                                                  within: .seconds(30))
        }
        let started = ContinuousClock.now
        let answer = await task.value
        #expect(answer == nil)
        #expect(ContinuousClock.now - started < .seconds(2))
    }

    @Test("no text, no question")
    func noTextNoQuestion() throws {
        var reading = Self.unsure()
        reading.ocrText = nil
        #expect(ReceiptModelCheck.question(for: reading,
                                           in: try BundledRuleSetLoader().ruleSet(for: 2025)) == nil)
    }

    @Test("the question offers only claimable reliefs, and numbers the candidates")
    func questionContents() throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let question = try #require(ReceiptModelCheck.question(for: Self.unsure(), in: rules))
        #expect(!question.reliefs.isEmpty)
        #expect(question.reliefs.allSatisfy { rules.relief(for: $0.code)?.automatic == false })
        #expect(question.prompt.contains("0: RM 54.00"))
        #expect(question.prompt.contains("1: RM 45.00"))
        #expect(question.prompt.contains("LIFESTYLE"))
    }

    // MARK: Through the pipeline

    static func pipeline(model: (any ReceiptModel)?) -> DocumentPipeline {
        DocumentPipeline(normaliser: ImageNormaliser(),
                         text: StubText(lines: ["KEDAI BUKU ANEKA", "TOTAL 45.00", "TOTAL 54.00"]),
                         pdfText: StubPDFText(), barcodes: StubBarcodes(),
                         now: { Date(timeIntervalSince1970: 1_750_000_000) },
                         model: model)
    }

    @Test("the pipeline applies a checked answer")
    func pipelineAppliesTheAnswer() async throws {
        let input = CaptureInput.image(try #require(SampleReceipt.jpeg()))
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let plain = try await Self.pipeline(model: nil).read(input, ruleSet: rules)
        #expect(plain.total?.isConfirmed == false, "precondition: two totals disagree")
        #expect(plain.totalCandidates.count == 2)

        let helped = try await Self.pipeline(model: StubModel(reply: ReceiptModelAnswer(
            vendor: nil, totalCandidate: 1, relief: nil))).read(input, ruleSet: rules)
        #expect(helped.total?.value == plain.totalCandidates[1])
        #expect(helped.total?.source == .model)
    }

    @Test("a failing model leaves the parser's reading exactly as it was")
    func pipelineIgnoresAFailingModel() async throws {
        let input = CaptureInput.image(try #require(SampleReceipt.jpeg()))
        let rules = try BundledRuleSetLoader().ruleSet(for: 2025)
        let plain = try await Self.pipeline(model: nil).read(input, ruleSet: rules)
        let failed = try await Self.pipeline(model: StubModel(fails: true)).read(input, ruleSet: rules)
        #expect(failed == plain)
    }
}
#endif
