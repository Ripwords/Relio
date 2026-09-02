import Foundation
import TaxKit
import TaxData

/// Every user-facing string a relief screen shows that is not already in the rulebook.
///
/// Some of it maps an enum that carries no display text of its own: those are plain
/// rulebook or payroll keys, so `String(describing:)` would otherwise leak a raw case
/// name like "maritalStatus" onto the screen. The rest is the contribution card, which is
/// copy too, assembled here so the view that shows it decides nothing.
///
/// Lives in `TaxPresentation`, not the view: `App/` sits outside `swift test`'s reach,
/// so a string kept there has zero test coverage. No switch here has a `default` —
/// a rulebook or a scheme adding a case must fail to compile, not silently misrender.
public enum ReliefCopy {

    /// A fact the app still needs to ask about, for the "to claim this" section of a
    /// relief's detail screen.
    public static func text(for question: ProfileQuestion) -> String {
        switch question {
        case .maritalStatus: "Marital status"
        case .spouseHasIncome: "Whether your spouse has income"
        case .assessmentType: "How you are assessed"
        case .employmentType: "Employment type"
        case .gender: "Gender"
        case .dependentDetails: "Dependant details"
        case .lastClaimYear: "When you last claimed this"
        case .propertyPrice: "Property price"
        case .disabilityStatus: "Disability status"
        case .spouseDisabilityStatus: "Your spouse's disability status"
        }
    }

    /// A name short enough to be a list row or a navigation title.
    ///
    /// The rulebook's own `name` is LHDN's description, written to remove ambiguity rather
    /// than to fit: "Lifestyle — books, computer, smartphone, tablet, internet, courses"
    /// wraps to four lines in a row and truncates in a toolbar. The full name stays where
    /// it reads well — the detail screen, and VoiceOver — and this is what the compact
    /// surfaces use.
    ///
    /// Editorial copy, so it lives here and not in `Resources/Rules/`: nothing in the
    /// rulebook should carry a string LHDN never published, or the `verifiedOn` stamp
    /// beside it stops meaning anything. `ReliefShortNameTests` is what keeps the table in
    /// step with the shipped codes, since `ReliefCode` is a string wrapper and a missing
    /// entry cannot be a compile error.
    ///
    /// - Parameter fullName: the rulebook's name, returned unchanged for a code this table
    ///   does not know. A rulebook shipped ahead of this file still renders.
    public static func shortName(for code: ReliefCode, fullName: String) -> String {
        shortNames[code] ?? fullName
    }

    private static let shortNames: [ReliefCode: String] = [
        .selfAndDependents: "Individual and dependants",
        .parentsMedical: "Parents and grandparents",
        .parentsCheckup: "Parents' medical checkup",
        .disabledEquipment: "Supporting equipment",
        .disabledSelf: "Disabled individual",
        .disabledSpouse: "Disabled spouse",
        .educationSelf: "Education fees",
        .educationUpskill: "Upskilling courses",
        .medicalSerious: "Serious medical",
        .medicalCheckup: "Medical checkup",
        .medicalDental: "Dental treatment",
        .medicalLearndis: "Learning disability care",
        .medicalVaccination: "Vaccination",
        .lifestyle: "Lifestyle",
        .lifestyleSports: "Lifestyle — sports",
        .breastfeeding: "Breastfeeding equipment",
        .childcare: "Childcare and kindergarten",
        .sspn: "SSPN net deposit",
        .spouseAlimony: "Spouse or alimony",
        .childUnder18: "Child under 18",
        .childPreTertiary: "Child in pre-degree study",
        .childTertiary: "Child in tertiary study",
        .childDisabled: "Disabled child",
        .childDisabledTertiary: "Disabled child, tertiary",
        .insuranceLifeEpf: "Life insurance and EPF",
        .lifeInsurance: "Life insurance",
        .epfContribution: "EPF contributions",
        .prsAnnuity: "PRS and deferred annuity",
        .insuranceEduMedical: "Education and medical cover",
        .socsoEis: "SOCSO and EIS",
        .evCharging: "EV charging and composting",
        .housingLoanInterest: "Housing loan interest",
    ]

    /// The same fact as `text(for:)`, phrased as the question the sheet actually asks.
    ///
    /// "Disability status" is a fine row label and a poor thing to put a Yes/No control
    /// under — the user has to guess which way round the answer runs. Every one of these
    /// is answerable without knowing any tax law, which is the bar: a question the user
    /// cannot answer confidently is worse than no question, because a wrong answer here
    /// silently changes what the app says they can claim.
    public static func question(for question: ProfileQuestion) -> String {
        switch question {
        case .maritalStatus: "What is your marital status?"
        case .spouseHasIncome: "Does your spouse have income of their own?"
        case .assessmentType: "How are you and your spouse assessed?"
        case .employmentType: "How are you employed?"
        case .gender: "What is your gender?"
        case .dependentDetails: "Tell us about your dependants"
        case .lastClaimYear: "When did you last claim this?"
        case .propertyPrice: "What did your first home cost?"
        case .disabilityStatus: "Are you registered with JKM as a person with a disability?"
        case .spouseDisabilityStatus: "Is your spouse registered with JKM as a person with a disability?"
        }
    }

    /// Why Relio is asking, shown under each question.
    ///
    /// Spec §1: an account-less app that asks for personal facts owes the user a reason
    /// for each one, in the place it asks. "Because the form said so" is how a tracker
    /// gets abandoned at the second question.
    public static func reasonForAsking(_ question: ProfileQuestion) -> String {
        switch question {
        case .maritalStatus:
            "Marital status decides whether the spouse and alimony reliefs apply to you."
        case .spouseHasIncome:
            "A spouse with no income of their own is what the spouse relief is for."
        case .assessmentType:
            "Joint and separate assessment claim child reliefs differently."
        case .employmentType:
            "Your EPF and SOCSO rates follow from how you are employed."
        case .gender:
            "Only the breastfeeding equipment relief depends on this."
        case .dependentDetails:
            "Each child's age and study level decides which child relief applies."
        case .lastClaimYear:
            "This relief can only be claimed once every few years."
        case .propertyPrice:
            "The housing loan interest cap is RM 7,000 up to RM 500,000, and RM 5,000 up to RM 750,000."
        case .disabilityStatus:
            "JKM registration unlocks the RM 7,000 disabled individual relief."
        case .spouseDisabilityStatus:
            "JKM registration unlocks the RM 6,000 disabled spouse relief."
        }
    }

    /// One published rule change, for the Compare screen's list of what moved.
    ///
    /// Phrased from the later year's point of view, because that is the direction the
    /// screen reads in — "rose to RM 4,000", not "was RM 3,000".
    public static func text(for delta: ReliefDelta, in year: Int) -> String {
        switch delta {
        case .added(_, _, let cap):
            "New in \(String(year)), up to \(cap.formatted())"
        case .removed(_, _, let supersededBy):
            supersededBy == nil
                ? "Withdrawn in \(String(year))"
                : "Merged into another relief in \(String(year))"
        case .capChanged(_, _, let from, let to):
            to > from
                ? "Cap rose from \(from.formatted()) to \(to.formatted())"
                : "Cap fell from \(from.formatted()) to \(to.formatted())"
        case .conditionsChanged:
            "The conditions changed"
        }
    }

    /// The relief a change is about, named the short way.
    public static func name(of delta: ReliefDelta) -> String {
        switch delta {
        case .added(let code, let name, _),
             .removed(let code, let name, _),
             .capChanged(let code, let name, _, _),
             .conditionsChanged(let code, let name, _, _):
            shortName(for: code, fullName: name)
        }
    }

    /// A required supporting document kind, for a relief's "Documents" section.
    public static func text(for kind: DocumentKind) -> String {
        switch kind {
        case .officialReceipt: "Official receipt"
        case .taxInvoice: "Tax invoice"
        case .eInvoice: "e-Invoice"
        case .medicalCertificate: "Medical certificate"
        case .referralLetter: "Referral letter"
        case .insuranceStatement: "Insurance statement"
        case .epfStatement: "EPF statement"
        case .bankStatement: "Bank statement"
        case .other: "Other document"
        }
    }
}

/// Everything a contribution screen shows above its entry list, resolved once so the view
/// renders it without re-deciding anything.
public struct ContributionCard: Hashable, Sendable {

    /// Kind and title travel together so a card cannot carry a button with no label, or a
    /// label with no button.
    public struct Action: Hashable, Sendable {
        public enum Kind: Hashable, Sendable {
            case addExactly(Money)
            case startFrom(Money)
            case answerQuestions
        }
        public let kind: Kind
        public let title: String
    }

    /// Rendered through `MoneyText`, never interpolated into `headline`.
    public let headlineAmount: Money?
    public let headline: String
    public let detail: String
    public let caveat: String?
    public let action: Action?
    public let sourceURLs: [URL]
}

extension ReliefCopy {

    /// The scheme's name as it appears mid-sentence.
    public static func text(for scheme: ContributionScheme) -> String {
        switch scheme {
        case .employeesProvidentFund: "EPF"
        case .socialSecurity: "SOCSO and EIS"
        }
    }

    /// The document that carries the true figure, for "enter what your X says".
    public static func statement(for scheme: ContributionScheme) -> String {
        switch scheme {
        case .employeesProvidentFund: "EPF statement"
        case .socialSecurity: "payslips"
        }
    }

    public static func text(for nationality: NationalityClass) -> String {
        switch nationality {
        case .malaysianCitizen: "Malaysian citizen"
        case .permanentResident: "Permanent resident"
        case .other: "Neither"
        }
    }

    /// `name` fills the slot in `.sourceDeducts` only. The other two ignore it, which is
    /// what lets one call site render a mixed list of questions without branching on the
    /// case before it asks for the text.
    public static func prompt(for question: ContributionQuestion,
                              sourceNamed name: String) -> String {
        switch question {
        case .dateOfBirth: "Your date of birth"
        case .nationality: "Your nationality"
        case .sourceDeducts(let scheme, _):
            "Does \(name) deduct \(text(for: scheme)) from your pay?"
        }
    }

    /// Shown under the date of birth question while it is still unanswered.
    ///
    /// The sheet cannot seed this control the way it seeds nothing else: a date picker
    /// opens on some date whether or not the user chose it, and this says out loud that
    /// the one on screen is not an answer until they make it one.
    public static let dateOfBirthFooter = "Relio will not fill this in for you. Pick your own date of birth, so the rate it quotes comes from your age rather than from a default."

    public static let questionsFooter = "Relio keeps these on your device. They decide "
        + "which statutory rate applies to each month of your salary, and nothing else."

    /// The whole contribution card for one relief screen, or `nil` when the screen has
    /// nothing to say.
    ///
    /// `cap` is the `ReliefAssessment.cap` the screen is already showing, so quoting it
    /// here introduces no figure the user has not already read.
    ///
    /// The scheme is derived here rather than passed in, so the view stays a renderer and
    /// never learns which relief codes are contribution codes.
    public static func card(for advice: ContributionAdvice,
                            code: ReliefCode,
                            year: Int,
                            cap: Money) -> ContributionCard? {
        guard let scheme = ContributionScheme.allCases.first(where: { $0.reliefCode == code })
        else { return nil }
        let schemeName = text(for: scheme)

        switch advice {
        case .none:
            return nil

        case .offer(let suggestion):
            let amount = suggestion.amount
            let basis = basisClause(suggestion.basis, year: year)
            switch suggestion.confidence {
            case .exactlyTheCap:
                return ContributionCard(
                    headlineAmount: amount,
                    headline: "The full limit",
                    detail: "\(basis) means you contributed at least \(amount.formatted()) "
                        + "to \(schemeName). That is the most this relief allows, so the "
                        + "figure is exact. Whatever your statement says, the relief is "
                        + "\(amount.formatted()).",
                    caveat: nil,
                    action: ContributionCard.Action(kind: .addExactly(amount),
                                                    title: "Add \(amount.formatted())"),
                    sourceURLs: suggestion.sourceURLs)
            case .atLeast:
                return ContributionCard(
                    headlineAmount: amount,
                    headline: "At least",
                    detail: "\(basis) proves this much. Your \(statement(for: scheme)) will "
                        + "show a little more, because the contribution schedule rounds each "
                        + "month up to a band. Enter the figure from your "
                        + "\(statement(for: scheme)).",
                    caveat: nil,
                    action: ContributionCard.Action(kind: .startFrom(amount),
                                                    title: "Start with \(amount.formatted())"),
                    sourceURLs: suggestion.sourceURLs)
            }

        case .answer(let questions, let worth):
            var detail = "\(countPhrase(questions.count)) and Relio will work out the least "
                + "you contributed to \(schemeName) in \(String(year)) from your salary records."
            if let worth {
                detail += " Worth about \(worth.formatted()) off your tax."
            }
            let caveat = switch scheme {
            case .employeesProvidentFund:
                "Relio won't guess. An 11% assumption is wrong for anyone aged 60 or over, "
                    + "who contributes nothing, and would overstate this relief by the full "
                    + "\(cap.formatted())."
            case .socialSecurity:
                "Relio won't guess. Which rate applies turns on your age and nationality, "
                    + "and assuming the wrong one would overstate this relief by up to the "
                    + "full \(cap.formatted())."
            }
            return ContributionCard(
                headlineAmount: nil,
                headline: "Relio can check this against your pay",
                detail: detail,
                caveat: caveat,
                action: ContributionCard.Action(
                    kind: .answerQuestions,
                    title: questions.count == 1 ? "Answer it" : "Answer them"),
                sourceURLs: [])

        case .crossCheck(let logged, let provenFloor):
            return ContributionCard(
                // Two figures are in play, so a headline amount would have to pick one of
                // them and the card's whole point is the gap between the pair.
                headlineAmount: nil,
                headline: "Worth checking your \(statement(for: scheme))",
                detail: "Your salary records prove you contributed at least "
                    + "\(provenFloor.formatted()) to \(schemeName) in \(String(year)). "
                    + "You have logged \(logged.formatted()).",
                // A floor bounds the contribution from below and nothing bounds it from
                // above, so this card can only ever mean an under-claim. Said out loud,
                // because a bare comparison of two figures reads as an accusation and the
                // user's own figure is the one Relio cannot contradict.
                caveat: "Relio can only ever prove a floor, never a ceiling, so this is "
                    + "never a sign you have claimed too much. If your "
                    + "\(statement(for: scheme)) shows more, raise the figure.",
                action: nil,
                sourceURLs: [])
        }
    }

    /// A lookup rather than a ladder of comparisons: the phrases are data, and the shape
    /// of the code should not suggest the counts mean anything to each other.
    private static let quickAnswerPhrases: [Int: String] = [
        1: "One quick answer",
        2: "Two quick answers",
        3: "Three quick answers",
        4: "Four quick answers",
        5: "Five quick answers"
    ]

    private static func countPhrase(_ count: Int) -> String {
        quickAnswerPhrases[count] ?? "A few quick answers"
    }

    /// What the floor was proved from, as the **subject of a sentence the offer cards
    /// finish** ("... means you contributed at least" against "... proves this much.").
    ///
    /// Two pieces of grammar the clause has to carry, because only it knows which shape it
    /// took. The head noun is singular in both forms, so the verb that follows agrees.
    /// And the named form ends in a comma, closing the appositive its months opened; the
    /// generic form has none to close.
    ///
    /// Naming the source and its months is only honest for a single source with a range
    /// to name. Several sources, or a source whose months are unknown, fall back to the
    /// generic clause rather than picking one of them to speak for the rest.
    private static func basisClause(_ basis: [ContributionBasis], year: Int) -> String {
        let generic = "Your recorded salary for \(String(year))"
        guard basis.count == 1, let entry = basis.first, let months = entry.months,
              let range = monthRange(months) else { return generic }
        return "Your salary from \(entry.name), \(range),"
    }

    private static func monthRange(_ months: ClosedRange<WageMonth>) -> String? {
        guard let first = monthName(months.lowerBound.month),
              let last = monthName(months.upperBound.month) else { return nil }
        if months.lowerBound == months.upperBound {
            return "\(first) \(String(months.lowerBound.year))"
        }
        if months.lowerBound.year == months.upperBound.year {
            return "\(first) to \(last) \(String(months.upperBound.year))"
        }
        return "\(first) \(String(months.lowerBound.year)) to \(last) "
            + "\(String(months.upperBound.year))"
    }

    /// Locale aware, so the clause reads in the user's own language wherever the rest of
    /// the app does.
    private static func monthName(_ month: Int) -> String? {
        let symbols = DateFormatter().monthSymbols ?? []
        guard symbols.indices.contains(month - 1) else { return nil }
        return symbols[month - 1]
    }
}
