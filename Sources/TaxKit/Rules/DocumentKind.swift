import Foundation

/// A kind of supporting document LHDN may require for a claim.
///
/// Requirement checking is a set difference between the kinds attached to an entry and
/// the kinds its relief declares, so these cases must stay in sync with the rulebook.
public enum DocumentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case officialReceipt
    case taxInvoice
    case eInvoice
    case medicalCertificate
    case referralLetter
    case insuranceStatement
    case epfStatement
    case bankStatement
    case other
}
