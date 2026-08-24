import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Models") struct ModelTests {

    @Test("a fresh TaxYear is empty rather than wrong")
    func freshYearIsEmpty() {
        let year = TaxYear(year: 2025)
        #expect(year.year == 2025)
        #expect(year.grossIncome == nil)
        #expect(year.maritalStatus == nil)
        #expect(year.deletedAt == nil)
        // distantPast, not Date(): "never stamped" must be detectable, and a default
        // that reads the clock would make two devices disagree about an untouched row.
        #expect(year.updatedAt == .distantPast)
    }

    @Test("computed accessors round-trip through raw storage")
    func accessorsRoundTrip() {
        let year = TaxYear(year: 2025)

        year.grossIncome = Money(ringgit: 128_000)
        #expect(year.grossIncomeSen == 12_800_000)
        #expect(year.grossIncome == Money(ringgit: 128_000))

        year.maritalStatus = .married
        #expect(year.maritalStatusRaw == "married")
        #expect(year.maritalStatus == .married)

        year.assessmentType = .separate
        year.employmentType = .privateSector
        year.gender = .female
        #expect(year.assessmentType == .separate)
        #expect(year.employmentType == .privateSector)
        #expect(year.gender == .female)

        year.grossIncome = nil
        #expect(year.grossIncomeSen == nil)
    }

    @Test("an unrecognised raw value reads as nil rather than trapping")
    func unknownRawValueIsNil() {
        let year = TaxYear(year: 2025)
        // A future schema version, or a device running an older build, can put a value
        // here this build has never heard of. Unknown must degrade to "not yet known",
        // which the engine already renders as .needsInfo, never crash the app.
        year.maritalStatusRaw = "civilPartnership"
        #expect(year.maritalStatus == nil)
    }

    @Test("a dependent's year statuses are stored inline and keyed by year")
    func dependentYearStatuses() {
        let child = Dependent(name: "Farah")
        child.kind = .child
        child.yearStatuses = [
            DependentYearStatus(year: 2024, educationLevel: .preTertiary, claimPercentage: 100, isFullTime: true),
            DependentYearStatus(year: 2025, educationLevel: .tertiaryLocal, claimPercentage: 50, isFullTime: true)
        ]
        #expect(child.status(for: 2025)?.educationLevel == .tertiaryLocal)
        #expect(child.status(for: 2025)?.claimPercentage == 50)
        #expect(child.status(for: 2023) == nil)
    }

    @Test("a dependent with no recorded status for the year yields nil, not a default")
    func missingStatusIsNil() {
        let child = Dependent(name: "Danish")
        // Defaulting to .none here would silently tell the engine "not in education",
        // which reads as ineligible for the education reliefs. nil reaches the engine as
        // an unanswered question and surfaces as a prompt instead.
        #expect(child.status(for: 2025) == nil)
    }

    @Test("an unasked disability question is nil, not false")
    func disabilityStartsUnknown() {
        let child = Dependent(name: "Danish")
        // false would mean "confirmed not disabled". Before the app asks, it knows
        // nothing, and the engine renders nothing as a prompt worth RM 6,000. Storing
        // false here would silently refuse the relief and never explain why.
        #expect(child.isDisabled == nil)
    }
}
