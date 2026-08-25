import TaxKit

/// User-facing copy for two `TaxKit` enums that carry no display text of their own —
/// both are plain rulebook keys, so `String(describing:)` would otherwise leak a raw
/// case name like "maritalStatus" onto the screen.
///
/// Lives in `TaxPresentation`, not the view: `App/` sits outside `swift test`'s reach,
/// so a mapping kept there has zero test coverage. Neither switch has a `default` —
/// a rulebook adding a case must fail to compile here, not silently misrender.
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
