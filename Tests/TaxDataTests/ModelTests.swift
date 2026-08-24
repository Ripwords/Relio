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

@Suite("Entry and document graph") struct EntryGraphTests {

    @Test("an entry round-trips its code, amount and claimant through raw storage")
    func entryAccessors() {
        let entry = ReliefEntry()
        entry.reliefCode = ReliefCode("LIFESTYLE")
        entry.amount = Money(ringgit: 1_820)
        entry.claimant = .individual

        #expect(entry.reliefCodeRaw == "LIFESTYLE")
        #expect(entry.amountSen == 182_000)
        #expect(entry.claimantRaw == "self")
        #expect(entry.reliefCode == ReliefCode("LIFESTYLE"))
        #expect(entry.amount == Money(ringgit: 1_820))
        #expect(entry.claimant == .individual)
    }

    @Test("an unrecognised claimant reads as individual rather than trapping")
    func unknownClaimantFallsBack() {
        let entry = ReliefEntry()
        entry.claimantRaw = "cousin"
        // A relief claimed for an unknown party is still the taxpayer's own claim as far
        // as this build can tell. Falling back keeps the row visible and editable; a trap
        // would take the whole list down over one bad row synced from a newer device.
        #expect(entry.claimant == .individual)
    }

    @Test("an entry belongs to a year and the year lists it")
    func entryYearInverse() throws {
        let container = try ModelContainer(
            for: Schema(SchemaInvariantTests.allModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        let entry = ReliefEntry()
        entry.reliefCode = ReliefCode("LIFESTYLE")
        entry.taxYear = year
        context.insert(year)
        context.insert(entry)
        try context.save()

        #expect(year.entries?.count == 1)
        #expect(year.entries?.first?.reliefCode == ReliefCode("LIFESTYLE"))
        #expect(entry.taxYear?.year == 2025)
    }

    @Test("one document can back two entries and one entry can hold two documents")
    func documentsAreManyToMany() throws {
        let container = try ModelContainer(
            for: Schema(SchemaInvariantTests.allModels),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = ModelContext(container)

        // Spec §5: a serious-illness claim needs a receipt AND a medical certificate,
        // and one hospital bill can back two different entries. Both directions matter,
        // and Task 6's sweep unions these links when it merges duplicates.
        let bill = Document(); bill.kind = .officialReceipt
        let certificate = Document(); certificate.kind = .medicalCertificate

        let serious = ReliefEntry(); serious.reliefCode = ReliefCode("MEDICAL_SERIOUS")
        let checkup = ReliefEntry(); checkup.reliefCode = ReliefCode("MEDICAL_CHECKUP")

        for object in [bill, certificate] { context.insert(object) }
        for object in [serious, checkup] { context.insert(object) }
        serious.documents = [bill, certificate]
        checkup.documents = [bill]
        try context.save()

        #expect(serious.documents?.count == 2)
        #expect(checkup.documents?.count == 1)
        #expect(bill.entries?.count == 2)
        #expect(certificate.entries?.count == 1)
    }

    @Test("download state round-trips without a Double")
    func downloadState() {
        let file = DocumentFile()
        file.downloadState = .downloading(percent: 42)
        #expect(file.downloadStateRaw == "downloading")
        #expect(file.downloadProgressPercent == 42)
        #expect(file.downloadState == .downloading(percent: 42))

        file.downloadState = .local
        #expect(file.downloadProgressPercent == 100)
        #expect(file.downloadState == .local)

        file.downloadState = .missing
        #expect(file.downloadState == .missing)
    }

    @Test("a percentage outside 0...100 is clamped rather than stored")
    func downloadProgressIsClamped() {
        let file = DocumentFile()
        file.downloadState = .downloading(percent: 250)
        #expect(file.downloadProgressPercent == 100)
        file.downloadState = .downloading(percent: -5)
        #expect(file.downloadProgressPercent == 0)
    }

    @Test("all five models remain CloudKit-mirroring-safe")
    func stillMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaInvariantTests.allModels))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }
}
