import Testing
import Foundation
@testable import TaxKit

@Suite("RuleSet decoding") struct RuleSetDecodingTests {

    static let sample = """
    {
      "yearOfAssessment": 2025,
      "revision": 1,
      "verifiedOn": "2026-08-23",
      "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
      "brackets": {
        "bands": [
          { "lowerSen": 0,       "upperSen": 500000,  "rate": "0",    "cumulativeBaseSen": 0 },
          { "lowerSen": 500000,  "upperSen": 2000000, "rate": "0.01", "cumulativeBaseSen": 0 },
          { "lowerSen": 200000000,               "rate": "0.30", "cumulativeBaseSen": 52840000 }
        ]
      },
      "reliefs": [
        {
          "code": "MEDICAL_SERIOUS",
          "name": "Medical - serious illness",
          "cap": { "kind": "fixed", "sen": 1000000 },
          "requiredDocuments": ["officialReceipt", "medicalCertificate"],
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
          "children": [
            {
              "code": "MEDICAL_DENTAL",
              "name": "Dental examination and treatment",
              "cap": { "kind": "fixed", "sen": 100000 },
              "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/"
            }
          ]
        },
        {
          "code": "CHILD_UNDER_18",
          "name": "Child under 18",
          "cap": { "kind": "perDependent", "sen": 200000 },
      "automatic": true,
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/"
        },
        {
          "code": "HOUSING_LOAN_INTEREST",
          "name": "Housing loan interest, first home",
          "cap": {
            "kind": "tiered",
            "on": "propertyPrice",
            "tiers": [
              { "maxSen": 50000000, "sen": 700000 },
              { "maxSen": 75000000, "sen": 500000 }
            ]
          },
          "sourceURL": "https://www.hasil.gov.my/individu/pelepasan-cukai/",
          "unverified": false
        }
      ],
      "retiredCodes": [
        { "retired": "BOOKS", "supersededBy": "LIFESTYLE", "fromYA": 2021 }
      ]
    }
    """

    func decoded() throws -> RuleSet {
        try JSONDecoder().decode(RuleSet.self, from: Data(Self.sample.utf8))
    }

    @Test("decodes the ruleset header")
    func header() throws {
        let rules = try decoded()
        #expect(rules.yearOfAssessment == 2025)
        #expect(rules.revision == 1)
        #expect(rules.verifiedOn == "2026-08-23")
        #expect(rules.verifiedOnDate != nil)
    }

    @Test("decodes rates from strings without floating-point error")
    func ratesAreExact() throws {
        let bands = try decoded().brackets.bands
        #expect(bands.count == 3)
        #expect(bands[1].rate == Decimal(string: "0.01")!)
        #expect(bands[0].lowerBound == Money.zero)
        #expect(bands[0].upperBound == Money(sen: 500_000))
        #expect(bands[2].upperBound == nil)
        #expect(bands[2].cumulativeBase == Money(sen: 52_840_000))
    }

    @Test("decodes every cap kind")
    func capKinds() throws {
        let reliefs = try decoded().reliefs
        #expect(reliefs[0].cap == .fixed(Money(sen: 1_000_000)))
        #expect(reliefs[1].cap == .perDependent(Money(sen: 200_000)))
        #expect(reliefs[2].cap == .tiered(on: .propertyPrice, tiers: [
            Tier(maxSen: 50_000_000, amount: Money(sen: 700_000)),
            Tier(maxSen: 75_000_000, amount: Money(sen: 500_000))
        ]))
    }

    @Test("omitted optional keys take safe defaults")
    func defaults() throws {
        let child = try decoded().reliefs[0].children[0]
        #expect(child.requiredDocuments.isEmpty)
        #expect(child.children.isEmpty)
        #expect(child.unverified == false)
        #expect(child.automatic == false)
    }

    @Test("required documents decode as typed kinds")
    func documentKinds() throws {
        #expect(try decoded().reliefs[0].requiredDocuments == [.officialReceipt, .medicalCertificate])
    }

    @Test("allReliefs flattens children depth-first")
    func flattening() throws {
        let codes = try decoded().allReliefs.map(\.code.rawValue)
        #expect(codes == ["MEDICAL_SERIOUS", "MEDICAL_DENTAL",
                          "CHILD_UNDER_18", "HOUSING_LOAN_INTEREST"])
    }

    @Test("retired codes decode with their successor")
    func retirements() throws {
        let retired = try decoded().retiredCodes
        #expect(retired.count == 1)
        #expect(retired[0].retired == ReliefCode("BOOKS"))
        #expect(retired[0].supersededBy == ReliefCode("LIFESTYLE"))
        #expect(retired[0].fromYA == 2021)
    }
}
