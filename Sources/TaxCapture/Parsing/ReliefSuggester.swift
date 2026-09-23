import Foundation
import TaxKit

/// Relief *candidates* from a receipt's words. Never a choice: the editor shows them
/// first in the picker and the user picks.
///
/// Straight to codes, not through `ReliefCategory` — that lives in `TaxPresentation`,
/// and a family is too coarse: "Health" holds eight reliefs and a dental receipt belongs
/// to one of them. Spec §4.
///
/// There is deliberately no pharmacy row. A pharmacy receipt is as often shampoo as
/// medicine, and a wrong suggestion at the top of the picker is worse than none.
public enum ReliefSuggester {

    struct Row {
        var keywords: [String]
        var codes: [ReliefCode]
    }

    /// Order matters: within one piece of text, earlier rows' codes come first. Dental and
    /// vaccination sit above the general clinic row so "KLINIK PERGIGIAN" leads with dental.
    static let table: [Row] = [
        Row(keywords: ["DENTAL", "PERGIGIAN", "DENTIST"], codes: [.medicalDental]),
        Row(keywords: ["VAKSIN", "VACCINE", "VACCINATION"], codes: [.medicalVaccination]),
        Row(keywords: ["KLINIK", "CLINIC", "HOSPITAL", "MEDICAL CENTRE", "PUSAT PERUBATAN"],
            codes: [.medicalSerious, .medicalCheckup]),
        Row(keywords: ["BUKU", "BOOK", "BOOKS", "BOOKSTORE", "BOOKSTORES", "MPH", "POPULAR",
                       "KINOKUNIYA", "MAJALAH", "MAGAZINE",
                       "COMPUTER", "KOMPUTER", "LAPTOP", "SMARTPHONE", "BROADBAND", "UNIFI"],
            codes: [.lifestyle]),
        Row(keywords: ["GYM", "FITNESS", "DECATHLON", "SPORTS", "SUKAN", "BADMINTON", "SWIMMING"],
            codes: [.lifestyleSports]),
        Row(keywords: ["TADIKA", "TASKA", "NURSERY", "CHILDCARE", "PUSAT JAGAAN",
                       "KINDERGARTEN", "PRESCHOOL"],
            codes: [.childcare]),
        Row(keywords: ["EV CHARGING", "EV CHARGER", "CHARGEEV", "GENTARI"], codes: [.evCharging]),
        Row(keywords: ["UNIVERSITI", "UNIVERSITY", "KOLEJ", "COLLEGE", "YURAN PENGAJIAN",
                       "TUITION FEE"],
            codes: [.educationSelf]),
        Row(keywords: ["SSPN"], codes: [.sspn]),
        Row(keywords: ["BREAST PUMP", "PAM SUSU"], codes: [.breastfeeding]),
        Row(keywords: ["INSURANCE", "INSURANS", "TAKAFUL"],
            codes: [.insuranceEduMedical, .lifeInsurance]),
    ]

    public static func suggest(vendor: String?, text: String, in ruleSet: RuleSet) -> [ReliefCode] {
        suggest(vendor: vendor, text: text, in: ruleSet, table: table)
    }

    static func suggest(vendor: String?, text: String, in ruleSet: RuleSet,
                        table: [Row]) -> [ReliefCode] {
        var codes: [ReliefCode] = []
        for phrase in [Phrase(vendor ?? ""), Phrase(text)] {
            for row in table where phrase.containsAny(row.keywords) {
                codes += row.codes
            }
        }
        var seen: Set<ReliefCode> = []
        return Array(codes
            .filter { seen.insert($0).inserted }
            .filter { code in ruleSet.relief(for: code).map { !$0.automatic } ?? false }
            .prefix(3))
    }
}
