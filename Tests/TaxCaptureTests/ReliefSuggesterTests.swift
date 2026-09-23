import Testing
import TaxKit
@testable import TaxCapture

@Suite("Suggesting reliefs from a receipt") struct ReliefSuggesterTests {

    static func rules(_ year: Int) throws -> RuleSet {
        try BundledRuleSetLoader().ruleSet(for: year)
    }

    @Test("each keyword row, against YA 2025", arguments: [
        ("KLINIK MEDIVIRON", [ReliefCode.medicalSerious, .medicalCheckup]),
        ("HOSPITAL PANTAI", [.medicalSerious, .medicalCheckup]),
        ("TOOTH DENTAL SURGERY", [.medicalDental]),
        ("KLINIK PERGIGIAN SENYUM", [.medicalDental, .medicalSerious, .medicalCheckup]),
        ("PUSAT VAKSIN", [.medicalVaccination]),
        ("KEDAI BUKU ILMU", [.lifestyle]),
        ("MPH BOOKSTORES", [.lifestyle]),
        ("LAPTOP WORLD", [.lifestyle]),
        ("ANYTIME GYM", [.lifestyleSports]),
        ("DECATHLON", [.lifestyleSports]),
        ("TADIKA CERIA", [.childcare]),
        ("GENTARI", [.evCharging]),
        ("UNIVERSITI MALAYA", [.educationSelf]),
        ("PERBADANAN SSPN", [.sspn]),
        ("PAM SUSU MURAH", [.breastfeeding]),
        ("ETIQA TAKAFUL", [.insuranceEduMedical, .lifeInsurance]),
    ])
    func rows(vendor: String, expected: [ReliefCode]) throws {
        #expect(ReliefSuggester.suggest(vendor: vendor, text: "", in: try Self.rules(2025))
                == expected)
    }

    @Test("a keyword matches a whole word only")
    func wholeWords() throws {
        #expect(ReliefSuggester.suggest(vendor: "BOOKING.COM", text: "", in: try Self.rules(2025))
                .isEmpty)
    }

    @Test("no match means no suggestions, not a guess")
    func noMatch() throws {
        #expect(ReliefSuggester.suggest(vendor: nil, text: "", in: try Self.rules(2025)).isEmpty)
        #expect(ReliefSuggester.suggest(vendor: "99 SPEED MART", text: "MILO 1KG",
                                        in: try Self.rules(2025)).isEmpty)
    }

    @Test("the vendor's matches come before the text's")
    func vendorFirst() throws {
        #expect(ReliefSuggester.suggest(vendor: "ANYTIME GYM", text: "BUKU LATIHAN",
                                        in: try Self.rules(2025))
                == [.lifestyleSports, .lifestyle])
    }

    @Test("never more than three")
    func atMostThree() throws {
        let codes = ReliefSuggester.suggest(vendor: "KLINIK PERGIGIAN", text: "VAKSIN BUKU",
                                            in: try Self.rules(2025))
        #expect(codes == [.medicalDental, .medicalSerious, .medicalCheckup])
    }

    /// MEDICAL_DENTAL first appears in YA 2024. A 2023 dental receipt must not suggest a
    /// relief that year's picker cannot even show.
    @Test("a code absent from that year's rulebook is never suggested")
    func respectsTheYear() throws {
        #expect(ReliefSuggester.suggest(vendor: "DENTAL CARE", text: "",
                                        in: try Self.rules(2023)).isEmpty)
    }

    @Test("an automatic relief is never suggested")
    func neverAutomatic() throws {
        let table = [ReliefSuggester.Row(keywords: ["ANYTHING"], codes: [.selfAndDependents])]
        #expect(ReliefSuggester.suggest(vendor: "ANYTHING", text: "",
                                        in: try Self.rules(2025), table: table).isEmpty)
    }

    @Test("every suggestion in every year is claimable", arguments: [2023, 2024, 2025])
    func everyRowIsClaimable(year: Int) throws {
        let rules = try Self.rules(year)
        for row in ReliefSuggester.table {
            for keyword in row.keywords {
                for code in ReliefSuggester.suggest(vendor: keyword, text: "", in: rules) {
                    let rule = try #require(rules.relief(for: code), "\(code) in \(year)")
                    #expect(rule.automatic == false, "\(code) in \(year)")
                }
            }
        }
    }
}
