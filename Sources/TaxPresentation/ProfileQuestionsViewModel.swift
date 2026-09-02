import Foundation
import Observation
import TaxKit
import TaxData

/// The facts a relief's eligibility is blocked on, asked so the user can unblock it.
///
/// Home has promised "answer 3 questions — unlock RM 20,000" since the first build and
/// had nowhere to send the tap. The engine's whole three-valued eligibility design exists
/// so an unasked question reads as "answer this and find out" rather than a silent "you
/// don't qualify" — and none of that reaches the user until something can take the answer.
///
/// Modelled on `ContributionQuestionsViewModel`, deliberately: same shape, same rule that
/// nothing defaults and `canSave` gates on a complete set. The store cannot tell an
/// answer apart from a default once it is written, and guessing here moves real money.
@MainActor
@Observable
public final class ProfileQuestionsViewModel {

    /// Only the questions this screen can actually save, in the order asked.
    public let questions: [ProfileQuestion]

    public var maritalStatus: MaritalStatus?
    public var spouseHasIncome: Bool?
    public var assessmentType: AssessmentType?
    public var employmentType: EmploymentType?
    public var gender: Gender?
    public var propertyPrice: Money?
    public var selfIsDisabled: Bool?
    public var spouseIsDisabled: Bool?

    /// Set when the write failed, so the sheet stays open and says so rather than
    /// dismissing over a save that did not happen — the failure mode onboarding was
    /// fixed for.
    public private(set) var saveError: String?

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore, questions: [ProfileQuestion]) {
        self.context = context
        self.store = store
        self.questions = Self.answerable(questions)
    }

    /// The questions that have somewhere to be written.
    ///
    /// Two of the ten cases have no `YearFacts` slot. `dependentDetails` belongs to a
    /// dependant row rather than to the year, and `lastClaimYear` has no storage anywhere
    /// in the app yet. Asking either one here would take an answer and drop it.
    ///
    /// `HomeViewModel` filters its count through this same function. That is what keeps
    /// the prompt honest: a count including a question this screen cannot save would let
    /// a user answer everything they are offered and still read "answer 1 question" for
    /// ever — the dead end moved one screen deeper rather than fixed.
    ///
    /// No `default` here, so a new `ProfileQuestion` case must be classified rather than
    /// silently falling into "cannot ask".
    public static func answerable(_ questions: [ProfileQuestion]) -> [ProfileQuestion] {
        questions.filter { question in
            switch question {
            case .maritalStatus, .spouseHasIncome, .assessmentType, .employmentType,
                 .gender, .propertyPrice, .disabilityStatus, .spouseDisabilityStatus:
                true
            case .dependentDetails, .lastClaimYear:
                false
            }
        }
    }

    /// Opens on what the store already holds. A control that opened empty would show a
    /// user their previous answer as unanswered, and overwrite it on the next save.
    public func load() async {
        guard let facts = try? await store.yearFacts(for: context.year) else { return }
        maritalStatus = facts.maritalStatus
        spouseHasIncome = facts.spouseHasIncome
        assessmentType = facts.assessmentType
        employmentType = facts.employmentType
        gender = facts.gender
        propertyPrice = facts.propertyPrice
        selfIsDisabled = facts.selfIsDisabled
        spouseIsDisabled = facts.spouseIsDisabled
    }

    /// Every question asked has an answer. Partial saves are refused rather than written,
    /// because a half-answered profile reads to the engine exactly like a fully answered
    /// one that happened to say no.
    public var canSave: Bool {
        questions.allSatisfy { isAnswered($0) }
    }

    public func isAnswered(_ question: ProfileQuestion) -> Bool {
        switch question {
        case .maritalStatus: maritalStatus != nil
        case .spouseHasIncome: spouseHasIncome != nil
        case .assessmentType: assessmentType != nil
        case .employmentType: employmentType != nil
        case .gender: gender != nil
        case .propertyPrice: propertyPrice != nil
        case .disabilityStatus: selfIsDisabled != nil
        case .spouseDisabilityStatus: spouseIsDisabled != nil
        case .dependentDetails, .lastClaimYear: false
        }
    }

    /// Read-modify-write, not write: the screen asks about one or two facts and must not
    /// blank the eight it never mentioned. `YearFacts` is a whole-value save, so anything
    /// this model did not load back would be erased by saving.
    public func save() async {
        saveError = nil
        do {
            var facts = try await store.yearFacts(for: context.year)
            for question in questions {
                switch question {
                case .maritalStatus: facts.maritalStatus = maritalStatus
                case .spouseHasIncome: facts.spouseHasIncome = spouseHasIncome
                case .assessmentType: facts.assessmentType = assessmentType
                case .employmentType: facts.employmentType = employmentType
                case .gender: facts.gender = gender
                case .propertyPrice: facts.propertyPrice = propertyPrice
                case .disabilityStatus: facts.selfIsDisabled = selfIsDisabled
                case .spouseDisabilityStatus: facts.spouseIsDisabled = spouseIsDisabled
                case .dependentDetails, .lastClaimYear: break
                }
            }
            try await store.saveYearFacts(facts, for: context.year)
            await context.reload()
        } catch {
            saveError = "Those answers could not be saved. Try again."
        }
    }
}
