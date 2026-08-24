import Testing
import Foundation
import TaxKit
@testable import TaxData

@Suite("Age at year end") struct AgeCalculatorTests {

    // 2018-03-14, 2006-06-02, 2009-09-21 — the golden persona's three children.
    static let aisyah = Date(timeIntervalSince1970: 1_521_000_000)
    static let danish = Date(timeIntervalSince1970: 1_149_206_400)
    static let farah  = Date(timeIntervalSince1970: 1_253_491_200)

    @Test("ages match the golden persona at the end of YA2025")
    func personaAges() {
        #expect(AgeCalculator.age(bornOn: Self.aisyah, atEndOf: 2025) == 7)
        #expect(AgeCalculator.age(bornOn: Self.danish, atEndOf: 2025) == 19)
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2025) == 16)
    }

    @Test("age is taken at 31 December, not on the day the code runs")
    func ageIsAtYearEnd() {
        // Born 21 September 2009: 15 at the end of 2024, 16 at the end of 2025. If this
        // read the clock instead, every golden file in the suite would rot on 1 January.
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2024) == 15)
        #expect(AgeCalculator.age(bornOn: Self.farah, atEndOf: 2025) == 16)
    }

    @Test("a birthday on 31 December counts that year")
    func birthdayOnTheBoundary() {
        // 2010-12-31 08:00 KL.
        let newYearsEve = Date(timeIntervalSince1970: 1_293_753_600)
        #expect(AgeCalculator.age(bornOn: newYearsEve, atEndOf: 2025) == 15)
    }

    @Test("age is negative before birth")
    func ageIsNegativeBeforeBirth() {
        let born2027 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        // AgeCalculator itself is the honest primitive: it returns the real signed
        // difference and does not clamp. Clamping a negative age to nil is the
        // projection's contract, not this type's — see
        // ProjectionTests.unbornDependentProjectsNilAge, which asserts it through
        // store.project(year:).
        #expect(AgeCalculator.age(bornOn: born2027, atEndOf: 2025) < 0)
    }
}

@Suite("Projection") struct ProjectionTests {

    @Test("year facts project into the snapshot the engine consumes")
    func yearFactsProject() async throws {
        let store = try await StoreFixture.store()
        var facts = YearFacts()
        facts.grossIncome = Money(ringgit: 128_000)
        facts.maritalStatus = .married
        facts.spouseHasIncome = false
        facts.assessmentType = .separate
        facts.employmentType = .privateSector
        facts.gender = .female
        facts.propertyPrice = Money(ringgit: 480_000)
        try await store.saveYearFacts(facts, for: 2025)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.year == 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 128_000))
        #expect(projected.snapshot.maritalStatus == .married)
        #expect(projected.snapshot.propertyPriceSen == 48_000_000)
        #expect(projected.snapshot.selfIsDisabled == nil)
    }

    @Test("dependents project with resolved ages and their year's status")
    func dependentsProject() async throws {
        let store = try await StoreFixture.store()
        var farah = DependentDraft(name: "Farah")
        farah.dateOfBirth = AgeCalculatorTests.farah
        farah.yearStatuses = [
            DependentYearStatus(year: 2024, educationLevel: .none, claimPercentage: 100, isFullTime: true),
            DependentYearStatus(year: 2025, educationLevel: .preTertiary, claimPercentage: 50, isFullTime: true)
        ]
        _ = try await store.save(farah)

        let projected = try await store.project(year: 2025)
        let dependent = try #require(projected.snapshot.dependents.first)
        #expect(dependent.ageAtYearEnd == 16)
        #expect(dependent.educationLevel == .preTertiary)
        #expect(dependent.claimPercentage == 50)
        #expect(dependent.isDisabled == nil)
    }

    @Test("a dependent with no status for the year projects education as nil")
    func missingStatusProjectsNil() async throws {
        let store = try await StoreFixture.store()
        var danish = DependentDraft(name: "Danish")
        danish.dateOfBirth = AgeCalculatorTests.danish
        _ = try await store.save(danish)

        let projected = try await store.project(year: 2025)
        let dependent = try #require(projected.snapshot.dependents.first)
        #expect(dependent.ageAtYearEnd == 19)
        #expect(dependent.educationLevel == nil, "unanswered, so the engine prompts")
        #expect(dependent.claimPercentage == 100, "the default share, not a guess about education")
    }

    @Test("a dependent with no date of birth projects a nil age")
    func missingBirthDateProjectsNilAge() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(DependentDraft(name: "Unknown"))
        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.dependents.first?.ageAtYearEnd == nil)
    }

    @Test("an unborn dependent projects a nil age, not a negative one")
    func unbornDependentProjectsNilAge() async throws {
        // Regression for the Critical: AgeCalculator.age(bornOn:atEndOf:) returns a
        // negative number for a birth date after the assessed year's end, and the
        // engine's dependentAge(max:) predicate tests `age > max` — so an unclamped
        // negative age (e.g. -1 > 18) reads as `.satisfied` and would silently grant
        // child relief to a not-yet-born dependent. This must go through
        // store.project(year:), not just AgeCalculator, because the clamp lives at the
        // projection seam.
        let store = try await StoreFixture.store()
        var unborn = DependentDraft(name: "Unborn")
        unborn.dateOfBirth = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15
        _ = try await store.save(unborn)

        let projected = try await store.project(year: 2025)
        let dependent = try #require(projected.snapshot.dependents.first)
        #expect(dependent.ageAtYearEnd == nil,
                "a negative age must not reach the engine, where `age > max` would silently satisfy an age-gated relief")
    }

    @Test("entries project with their code, amount, claimant and document kinds")
    func entriesProject() async throws {
        let store = try await StoreFixture.store()
        let id = try await store.save(StoreFixture.entry("MEDICAL_SERIOUS", 6_500))
        try await store.attachDocumentForTesting(kind: .officialReceipt, toEntry: id)
        try await store.attachDocumentForTesting(kind: .medicalCertificate, toEntry: id)

        let projected = try await store.project(year: 2025)
        let entry = try #require(projected.entries.first)
        #expect(entry.id == id)
        #expect(entry.code == ReliefCode("MEDICAL_SERIOUS"))
        #expect(entry.amount == Money(ringgit: 6_500))
        #expect(entry.claimant == .individual)
        #expect(entry.documentKinds == [.officialReceipt, .medicalCertificate])
    }

    @Test("soft-deleted and merged entries do not reach the engine")
    func deletedEntriesAreExcluded() async throws {
        let store = try await StoreFixture.store()
        let kept = try await store.save(StoreFixture.entry("LIFESTYLE", 1_820))
        var other = StoreFixture.entry("SSPN", 3_000)
        other.id = UUID()
        let removed = try await store.save(other)
        try await store.softDeleteEntry(id: removed)

        let projected = try await store.project(year: 2025)
        // A deleted entry that still reduced chargeable income would understate tax on a
        // figure the user believes they removed.
        #expect(projected.entries.map(\.id) == [kept])
    }

    @Test("prior-year claims become claim history, and no history means absent")
    func claimHistoryIsDerived() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE_PC", 2_500, year: 2023))
        var current = StoreFixture.entry("LIFESTYLE", 1_820, year: 2025)
        current.id = UUID()
        _ = try await store.save(current)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("LIFESTYLE_PC")] == 2023)
        // Absent, not zero and not "never": the app cannot know what the user claimed
        // before they adopted it, and assuming "never" would over-grant a
        // once-every-N-years relief. Absent reads as .unknown in the engine.
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("SSPN")] == nil)
    }

    @Test("the current year is not its own claim history")
    func currentYearIsNotHistory() async throws {
        let store = try await StoreFixture.store()
        _ = try await store.save(StoreFixture.entry("LIFESTYLE_PC", 2_500, year: 2025))
        let projected = try await store.project(year: 2025)
        // Otherwise every relief claimed this year would immediately look like it was
        // "last claimed 0 years ago" and block itself.
        #expect(projected.snapshot.lastClaimedYear[ReliefCode("LIFESTYLE_PC")] == nil)
    }

    @Test("projection is ordered deterministically")
    func projectionIsOrdered() async throws {
        let store = try await StoreFixture.store()
        for code in ["SSPN", "LIFESTYLE", "MEDICAL_CHECKUP"] {
            var draft = StoreFixture.entry(code, 100)
            draft.id = UUID()
            _ = try await store.save(draft)
        }
        let first = try await store.project(year: 2025).entries.map(\.id)
        let second = try await store.project(year: 2025).entries.map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }

    @Test("dependent projection is ordered deterministically")
    func dependentProjectionIsOrdered() async throws {
        let store = try await StoreFixture.store()
        for name in ["Farah", "Danish", "Aisyah"] {
            _ = try await store.save(DependentDraft(name: name))
        }
        let first = try await store.project(year: 2025).snapshot.dependents.map(\.id)
        let second = try await store.project(year: 2025).snapshot.dependents.map(\.id)
        #expect(first == second)
        #expect(first == first.sorted { $0.uuidString < $1.uuidString })
    }
}
