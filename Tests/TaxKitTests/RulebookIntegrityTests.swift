import Testing
import Foundation
@testable import TaxKit

@Suite("Rulebook integrity") struct RulebookIntegrityTests {

    /// Every YA shipped in the bundle. Extended in Task 9.
    static let shippedYears = [2025]

    static func load(_ year: Int) throws -> RuleSet {
        let url = try #require(
            Bundle.module.url(forResource: "ya-\(year)", withExtension: "json",
                              subdirectory: "Rules"),
            "ya-\(year).json is not in the bundle")
        return try JSONDecoder().decode(RuleSet.self, from: try Data(contentsOf: url))
    }

    @Test("every shipped year decodes", arguments: shippedYears)
    func decodes(year: Int) throws {
        #expect(try Self.load(year).yearOfAssessment == year)
    }

    @Test("verifiedOn is a real ISO date", arguments: shippedYears)
    func verifiedOnIsValid(year: Int) throws {
        let rules = try Self.load(year)
        #expect(rules.verifiedOn.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) != nil)
        #expect(rules.verifiedOnDate != nil)
    }

    @Test("every relief cites an LHDN source", arguments: shippedYears)
    func everyReliefHasASource(year: Int) throws {
        for relief in try Self.load(year).allReliefs {
            #expect(relief.sourceURL.host()?.hasSuffix("hasil.gov.my") == true,
                    "\(relief.code) cites \(relief.sourceURL)")
        }
    }

    @Test("relief codes are unique within a year", arguments: shippedYears)
    func codesAreUnique(year: Int) throws {
        let codes = try Self.load(year).allReliefs.map(\.code.rawValue)
        #expect(codes.count == Set(codes).count)
    }

    @Test("no relief is left marked unverified", arguments: shippedYears)
    func nothingUnverified(year: Int) throws {
        let unverified = try Self.load(year).allReliefs.filter(\.unverified).map(\.code.rawValue)
        #expect(unverified.isEmpty, "unverified: \(unverified)")
    }

    @Test("sub-limits never exceed their parent's ceiling", arguments: shippedYears)
    func childCapsFitInsideParents(year: Int) throws {
        for parent in try Self.load(year).reliefs {
            for child in parent.children {
                #expect(child.cap.nominalCeiling <= parent.cap.nominalCeiling,
                        "\(child.code) exceeds \(parent.code)")
            }
        }
    }

    @Test("bands are contiguous, ascending, and only the last is open-ended",
          arguments: shippedYears)
    func bandsAreWellFormed(year: Int) throws {
        let bands = try Self.load(year).brackets.bands
        #expect(bands.first?.lowerBound == .zero)
        for (index, band) in bands.enumerated() {
            if index == bands.count - 1 {
                #expect(band.upperBound == nil, "the top band must be open-ended")
            } else {
                let upper = try #require(band.upperBound)
                #expect(upper == bands[index + 1].lowerBound,
                        "gap or overlap after band \(index)")
                #expect(band.rate <= bands[index + 1].rate, "rates must not decrease")
            }
        }
    }

    @Test("each band's cumulative base equals the previous base plus the previous band's tax",
          arguments: shippedYears)
    func cumulativeBasesAreConsistent(year: Int) throws {
        let bands = try Self.load(year).brackets.bands
        for index in 1..<bands.count {
            let previous = bands[index - 1]
            let width = try #require(previous.upperBound) - previous.lowerBound
            let expected = previous.cumulativeBase + width.applying(previous.rate)
            #expect(bands[index].cumulativeBase == expected,
                    "band \(index) base is \(bands[index].cumulativeBase.formatted()), expected \(expected.formatted())")
        }
    }

    @Test("YA2025 carries the reliefs LHDN publishes")
    func ya2025Spot() throws {
        let rules = try Self.load(2025)
        #expect(rules.relief(for: .lifestyle)?.cap == .fixed(Money(ringgit: 2500)))
        #expect(rules.relief(for: ReliefCode("DISABLED_SELF"))?.cap == .fixed(Money(ringgit: 7000)))
        #expect(rules.relief(for: ReliefCode("DISABLED_SPOUSE"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("INSURANCE_EDU_MEDICAL"))?.cap == .fixed(Money(ringgit: 4000)))
        #expect(rules.relief(for: ReliefCode("MEDICAL_LEARNDIS"))?.cap == .fixed(Money(ringgit: 6000)))
        #expect(rules.relief(for: ReliefCode("SOCSO_EIS"))?.cap == .fixed(Money(ringgit: 350)))
        #expect(rules.relief(for: ReliefCode("HOUSING_LOAN_INTEREST")) != nil)
    }

    @Test("exactly the household-derived reliefs are automatic", arguments: shippedYears)
    func automaticSet(year: Int) throws {
        let automatic = Set(try Self.load(year).allReliefs
            .filter(\.automatic).map(\.code.rawValue))
        // The automatic set is identical in all three shipped years.
        #expect(automatic == [
            "SELF_AND_DEPENDENTS", "SPOUSE_ALIMONY", "DISABLED_SELF", "DISABLED_SPOUSE",
            "CHILD_UNDER_18", "CHILD_PRE_TERTIARY", "CHILD_TERTIARY",
            "CHILD_DISABLED", "CHILD_DISABLED_TERTIARY"
        ])
    }

    @Test("every automatic relief is gated or unconditional, never a free grant",
          arguments: shippedYears)
    func automaticRelievesAreGated(year: Int) throws {
        for relief in try Self.load(year).allReliefs where relief.automatic {
            let gated = relief.eligibility != nil
            let perDependent = if case .perDependent = relief.cap { true } else { false }
            let unconditional = relief.code == ReliefCode("SELF_AND_DEPENDENTS")
            #expect(gated || perDependent || unconditional,
                    "\(relief.code) is automatic with nothing gating it")
        }
    }
}
