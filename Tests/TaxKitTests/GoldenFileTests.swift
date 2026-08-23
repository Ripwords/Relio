import Testing
import Foundation
@testable import TaxKit

@Suite("Golden files") struct GoldenFileTests {

    /// A married Kuala Lumpur salaryman with three children and a first home.
    /// Deliberately exercises fixed caps, sub-limits, per-dependent caps, tiered caps,
    /// a satisfied requirement, a missing requirement and an unresolved code.
    enum Persona {
        static func id(_ n: Int) -> UUID {
            UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
        }

        static let children = [
            DependentSnapshot(id: id(101), name: "Aisyah", ageAtYearEnd: 7,
                              educationLevel: EducationLevel.none, claimPercentage: 100),
            DependentSnapshot(id: id(102), name: "Danish", ageAtYearEnd: 19,
                              educationLevel: .tertiaryLocal, claimPercentage: 100),
            DependentSnapshot(id: id(103), name: "Farah", ageAtYearEnd: 16,
                              educationLevel: .preTertiary, claimPercentage: 50)
        ]

        static func year(_ ya: Int) -> TaxYearSnapshot {
            TaxYearSnapshot(year: ya,
                            grossIncome: Money(ringgit: 128_000),
                            maritalStatus: .married,
                            spouseHasIncome: false,
                            assessmentType: .separate,
                            employmentType: .privateSector,
                            gender: .female,
                            dependents: children,
                            propertyPriceSen: Money(ringgit: 480_000).sen,
                            lastClaimedYear: [:])
        }

        static let entries: [EntrySnapshot] = [
            EntrySnapshot(id: id(1), code: .lifestyle, amount: Money(ringgit: 1_820),
                          documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(2), code: ReliefCode("LIFESTYLE_SPORTS"),
                          amount: Money(ringgit: 1_400), documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(3), code: ReliefCode("MEDICAL_SERIOUS"),
                          amount: Money(ringgit: 6_500),
                          documentKinds: [.officialReceipt, .medicalCertificate]),
            EntrySnapshot(id: id(4), code: ReliefCode("MEDICAL_CHECKUP"),
                          amount: Money(ringgit: 900), documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(5), code: ReliefCode("EPF_CONTRIBUTION"),
                          amount: Money(ringgit: 4_600), documentKinds: [.epfStatement]),
            EntrySnapshot(id: id(6), code: ReliefCode("LIFE_INSURANCE"),
                          amount: Money(ringgit: 2_100), documentKinds: []),   // missing doc
            EntrySnapshot(id: id(7), code: ReliefCode("SSPN"),
                          amount: Money(ringgit: 3_000), documentKinds: [.bankStatement]),
            EntrySnapshot(id: id(8), code: ReliefCode("CHILDCARE"),
                          amount: Money(ringgit: 2_400), dependentID: id(101),
                          documentKinds: [.officialReceipt]),
            EntrySnapshot(id: id(9), code: ReliefCode("HOUSING_LOAN_INTEREST"),
                          amount: Money(ringgit: 9_100), documentKinds: [.bankStatement]),
            EntrySnapshot(id: id(10), code: ReliefCode("SOCSO_EIS"),
                          amount: Money(ringgit: 350), documentKinds: [])
        ]
    }

    static var fixturesDirectory: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures")
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    @Test("the persona's assessment matches the recorded golden file",
          arguments: [2023, 2024, 2025])
    func matchesGolden(year: Int) throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: year)
        let result = evaluate(ruleSet: rules,
                              year: Persona.year(year),
                              entries: Persona.entries)
        let produced = try Self.encoder().encode(result)
        let file = Self.fixturesDirectory.appending(path: "golden-ya\(year).json")

        // Re-record with: TAXKIT_RECORD=1 swift test --filter GoldenFileTests
        if ProcessInfo.processInfo.environment["TAXKIT_RECORD"] == "1" {
            try produced.write(to: file)
            return
        }

        let expected = try #require(try? Data(contentsOf: file),
                                    "golden-ya\(year).json missing — record it first")
        #expect(String(data: produced, encoding: .utf8)
                == String(data: expected, encoding: .utf8))
    }

    @Test("the persona is realistic enough to exercise the whole engine")
    func personaCoversTheEngine() throws {
        let result = evaluate(ruleSet: try BundledRuleSetLoader().ruleSet(for: 2025),
                              year: Persona.year(2025),
                              entries: Persona.entries)

        // Over-claimed against a fixed cap.
        #expect(result.assessment(for: ReliefCode("LIFESTYLE_SPORTS"))?.allowed
                == Money(ringgit: 1_000))
        // Sub-limit inside a parent ceiling.
        #expect(result.assessment(for: ReliefCode("MEDICAL_CHECKUP"))?.allowed
                == Money(ringgit: 900))
        // Per-dependent cap: one under-18 at 100%, one pre-tertiary 16-year-old is
        // under 18 too, one tertiary 19-year-old is not.
        #expect(result.assessment(for: ReliefCode("CHILD_TERTIARY"))?.cap
                == Money(ringgit: 8_000))
        // Tiered cap: RM 480,000 home selects the RM 7,000 tier.
        #expect(result.assessment(for: ReliefCode("HOUSING_LOAN_INTEREST"))?.cap
                == Money(ringgit: 7_000))
        // A missing document is reported.
        let life = try #require(result.assessment(for: ReliefCode("LIFE_INSURANCE")))
        #expect(life.requirements.contains { !$0.isSatisfied })
        // Income figures are present.
        #expect(result.chargeableIncome != nil)
        #expect(result.totalOpportunity != nil)
    }

    @Test("the same persona under YA2024 loses the housing relief to unresolved")
    func housingUnresolvedInEarlierYears() throws {
        let result = evaluate(ruleSet: try BundledRuleSetLoader().ruleSet(for: 2024),
                              year: Persona.year(2024),
                              entries: Persona.entries)
        #expect(result.unresolved.contains {
            $0.code == ReliefCode("HOUSING_LOAN_INTEREST")
                && $0.reason == .unknownInThisYear
        })
    }

    @Test("golden files are deterministic across repeated evaluation",
          arguments: [2023, 2024, 2025])
    func evaluationIsDeterministic(year: Int) throws {
        let rules = try BundledRuleSetLoader().ruleSet(for: year)
        let first = evaluate(ruleSet: rules, year: Persona.year(year), entries: Persona.entries)
        let second = evaluate(ruleSet: rules, year: Persona.year(year), entries: Persona.entries)
        #expect(first == second)
    }
}
