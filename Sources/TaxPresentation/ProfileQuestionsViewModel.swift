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

    /// Whether Save waits for a complete set.
    ///
    /// True when Home sent the user here to clear a specific prompt: answering two of
    /// three and saving would leave the prompt on Home saying one is left, which reads as
    /// the save having failed.
    ///
    /// False in Settings, where the same eight questions are a profile to edit rather
    /// than a task to finish. Someone who owns no property cannot answer "what did your
    /// first home cost?", and gating on completeness there would lock them out of
    /// changing their marital status for ever.
    public let requiresEveryAnswer: Bool

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

    /// Whether `load()` has run.
    ///
    /// `save()` writes every asked question's current value, including nil. A screen that
    /// forgot to load first would therefore write nil over facts the user had already
    /// given — and from Settings, where all eight questions are asked, that is every
    /// household fact they own, on a Save that looks like it is confirming what is on
    /// screen. That is exactly what shipped: the sheet had no `.task`, so it opened blank
    /// against a married profile and Save would have blanked it.
    ///
    /// Guarding here rather than only fixing the view: the view is one caller of several,
    /// and a rule the model enforces cannot be forgotten by the next one.
    public private(set) var hasLoaded = false

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext,
                store: TaxStore,
                questions: [ProfileQuestion],
                requiresEveryAnswer: Bool = true) {
        self.context = context
        self.store = store
        self.questions = Self.answerable(questions)
        self.requiresEveryAnswer = requiresEveryAnswer
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
        hasLoaded = true
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
        guard requiresEveryAnswer else { return true }
        return questions.allSatisfy { isAnswered($0) }
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
        // Refuses rather than wipes. See `hasLoaded`.
        guard hasLoaded else {
            saveError = "Those answers could not be saved. Try again."
            return
        }
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
