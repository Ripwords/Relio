import Testing
import Foundation
import TaxKit
@testable import TaxData

/// The same household Plan 1's `GoldenFileTests` describes, seeded through `TaxStore`
/// rather than constructed as snapshots in memory.
@Suite("Persisted golden persona") struct PersistedGoldenTests {

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: "00000000-0000-0000-0000-\(String(format: "%012d", n))")!
    }

    /// Birth dates chosen to resolve to the persona's ages at the end of YA2025:
    /// 7, 19 and 16 respectively.
    static let aisyahBorn = Date(timeIntervalSince1970: 1_521_000_000)   // 2018-03-14
    static let danishBorn = Date(timeIntervalSince1970: 1_149_206_400)   // 2006-06-02
    static let farahBorn  = Date(timeIntervalSince1970: 1_253_491_200)   // 2009-09-21

    static func seed(_ store: TaxStore) async throws {
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        var aisyah = DependentDraft(id: id(101), name: "Aisyah")
        aisyah.dateOfBirth = aisyahBorn
        aisyah.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .none,
                                                   claimPercentage: 100, isFullTime: false)]
        var danish = DependentDraft(id: id(102), name: "Danish")
        danish.dateOfBirth = danishBorn
        danish.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .tertiaryLocal,
                                                   claimPercentage: 100, isFullTime: true)]
        var farah = DependentDraft(id: id(103), name: "Farah")
        farah.dateOfBirth = farahBorn
        farah.yearStatuses = [DependentYearStatus(year: 2025, educationLevel: .preTertiary,
                                                  claimPercentage: 50, isFullTime: true)]
        for dependent in [aisyah, danish, farah] { _ = try await store.save(dependent) }

        let entries: [(Int, String, Decimal, UUID?, Set<DocumentKind>)] = [
            (1,  "LIFESTYLE",             1_820, nil,      [.officialReceipt]),
            (2,  "LIFESTYLE_SPORTS",      1_400, nil,      [.officialReceipt]),
            (3,  "MEDICAL_SERIOUS",       6_500, nil,      [.officialReceipt, .medicalCertificate]),
            (4,  "MEDICAL_CHECKUP",         900, nil,      [.officialReceipt]),
            (5,  "EPF_CONTRIBUTION",      4_600, nil,      [.epfStatement]),
            (6,  "LIFE_INSURANCE",        2_100, nil,      []),
            (7,  "SSPN",                  3_000, nil,      [.bankStatement]),
            (8,  "CHILDCARE",             2_400, id(101),  [.officialReceipt]),
            (9,  "HOUSING_LOAN_INTEREST", 9_100, nil,      [.bankStatement]),
            (10, "SOCSO_EIS",               350, nil,      [])
        ]

        for (number, code, ringgit, dependentID, documents) in entries {
            let draft = EntryDraft(id: id(number),
                                   year: 2025,
                                   code: ReliefCode(code),
                                   amount: Money(ringgit: ringgit),
                                   dependentID: dependentID)
            let saved = try await store.save(draft)
            for kind in documents.sorted(by: { $0.rawValue < $1.rawValue }) {
                try await store.attachDocumentForTesting(kind: kind, toEntry: saved)
            }
        }
    }

    /// The single golden file, in `TaxKitTests`. Referenced rather than copied so the
    /// two suites cannot drift apart.
    static var goldenURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // Tests/TaxDataTests
            .deletingLastPathComponent()      // Tests
            .appending(path: "TaxKitTests/Fixtures/golden-ya2025.json")
    }

    static func evaluatePersisted(_ store: TaxStore) async throws -> EvaluationResult {
        let projected = try await store.project(year: 2025)
        let ruleSet = try BundledRuleSetLoader().ruleSet(for: 2025)
        return evaluate(ruleSet: ruleSet, year: projected.snapshot, entries: projected.entries)
    }

    @Test("seeding through TaxStore reproduces the golden YA2025 result exactly")
    func persistedPersonaMatchesGolden() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)

        let produced = try await Self.evaluatePersisted(store)
        let expected = try JSONDecoder().decode(EvaluationResult.self,
                                                from: Data(contentsOf: Self.goldenURL))

        // Compare field by field before the whole-value assertion: `#expect(a == b)` on a
        // 30-node tree reports "not equal" and nothing else, which is useless to whoever
        // has to fix it.
        #expect(produced.chargeableIncome == expected.chargeableIncome)
        #expect(produced.estimatedTax == expected.estimatedTax)
        #expect(produced.totalAllowed == expected.totalAllowed)
        #expect(produced.totalOpportunity == expected.totalOpportunity)
        #expect(produced.assessments.map(\.code) == expected.assessments.map(\.code))
        #expect(produced.unresolved == expected.unresolved)

        for expectedAssessment in expected.allAssessments {
            let actual = produced.assessment(for: expectedAssessment.code)
            #expect(actual?.allowed == expectedAssessment.allowed,
                    "\(expectedAssessment.code) allowed")
            #expect(actual?.eligibility == expectedAssessment.eligibility,
                    "\(expectedAssessment.code) eligibility")
            #expect(actual?.taxSaved == expectedAssessment.taxSaved,
                    "\(expectedAssessment.code) taxSaved")
        }

        #expect(produced == expected)
    }

    @Test("the reconciliation sweep does not change the result")
    func sweepPreservesTheResult() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)
        let before = try await Self.evaluatePersisted(store)

        #expect(try await store.reconcile().isEmpty, "the persona contains no duplicates")
        let after = try await Self.evaluatePersisted(store)
        #expect(after == before)
    }

    @Test("a duplicated receipt overstates relief, and the sweep restores the truth")
    func sweepRemovesAnOverstatement() async throws {
        let store = try await StoreFixture.store()
        try await Self.seed(store)
        let golden = try await Self.evaluatePersisted(store)

        // The same RM 1,820 of books logged twice — the exact failure CloudKit's lack of
        // unique constraints makes possible, and the reason the sweep exists.
        var duplicate = EntryDraft(id: UUID(),
                                   year: 2025,
                                   code: ReliefCode("LIFESTYLE"),
                                   amount: Money(ringgit: 1_820))
        duplicate.vendor = ""
        _ = try await store.save(duplicate)

        let inflated = try await Self.evaluatePersisted(store)
        #expect(inflated.assessment(for: ReliefCode("LIFESTYLE"))?.claimed
                != golden.assessment(for: ReliefCode("LIFESTYLE"))?.claimed,
                "the duplicate must actually be visible to the engine, or this proves nothing")

        let reports = try await store.reconcile()
        #expect(reports.count == 1)
        let repaired = try await Self.evaluatePersisted(store)
        #expect(repaired.assessment(for: ReliefCode("LIFESTYLE"))?.claimed
                == golden.assessment(for: ReliefCode("LIFESTYLE"))?.claimed)
    }

    @Test("projecting an empty store still evaluates, granting only automatic reliefs")
    func emptyStoreEvaluates() async throws {
        let store = try await StoreFixture.store()
        let result = try await Self.evaluatePersisted(store)
        // First launch, before onboarding. The screen must show a number, not an error.
        #expect(result.unresolved.isEmpty)
        #expect(result.totalAllowed > Money.zero, "the individual relief is automatic")
    }
}
