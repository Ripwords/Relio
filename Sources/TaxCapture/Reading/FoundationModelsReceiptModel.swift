#if canImport(FoundationModels)
import FoundationModels

@Generable
struct GeneratedReceiptAnswer {
    @Guide(description: "Merchant name exactly as printed on the receipt, or null")
    var vendor: String?
    @Guide(description: "Index of the grand total among the numbered total candidates, or null")
    var totalCandidate: Int?
    @Guide(description: "Code of the best-matching relief among those listed, or null")
    var relief: String?
}

/// Apple's on-device model. Nil where it is not available — older hardware, Apple
/// Intelligence off, the model still downloading — and the pipeline then runs without it.
public struct FoundationModelsReceiptModel: ReceiptModel {

    static let instructions = """
        You read Malaysian shop receipts. Answer only from the receipt text you are given. \
        Choose the grand total by its index among the total candidates. Choose a relief \
        only from the codes listed. Use null for anything you are not sure of.
        """

    public init?() {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
    }

    public func answer(_ question: ReceiptModelQuestion) async throws -> ReceiptModelAnswer {
        let session = LanguageModelSession(instructions: Self.instructions)
        let response = try await session.respond(to: question.prompt,
                                                 generating: GeneratedReceiptAnswer.self)
        return ReceiptModelAnswer(vendor: response.content.vendor,
                                  totalCandidate: response.content.totalCandidate,
                                  relief: response.content.relief)
    }
}
#endif
