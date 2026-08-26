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
        facts.grossIncomeOverride = Money(ringgit: 128_000)
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

@Suite("Income projection") struct IncomeProjectionTests {

    static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents(); c.year = y; c.month = m; c.day = d; c.hour = 12
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return cal.date(from: c)!
    }

    static func seedSalary(_ store: TaxStore, _ ringgit: Decimal) async throws {
        let sourceID = try await store.save(IncomeSourceDraft(name: "Main job"))
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: ringgit)
        rate.effectiveFrom = date(2025, 1, 1)
        _ = try await store.save(rate)
    }

    @Test("with no override, the projection uses the derived figure")
    func derivedReachesTheEngine() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 96_000))
    }

    @Test("an override wins over the derived figure")
    func overrideWins() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        var facts = try await store.yearFacts(for: 2025)
        // The EA form is authoritative: it includes benefits-in-kind and allowances Relio
        // never saw. When the user says the real total, that is the total.
        facts.grossIncomeOverride = Money(ringgit: 101_500)
        try await store.saveYearFacts(facts, for: 2025)

        let projected = try await store.project(year: 2025)
        #expect(projected.snapshot.grossIncome == Money(ringgit: 101_500))
    }

    @Test("clearing the override returns to the derived figure")
    func clearingOverrideReverts() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        var facts = try await store.yearFacts(for: 2025)
        facts.grossIncomeOverride = Money(ringgit: 101_500)
        try await store.saveYearFacts(facts, for: 2025)
        facts.grossIncomeOverride = nil
        try await store.saveYearFacts(facts, for: 2025)

        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money(ringgit: 96_000))
    }

    @Test("no income at all still projects nil, not zero")
    func noIncomeIsUnknown() async throws {
        let store = try await StoreFixture.store()
        // nil means "not known", which the engine renders as no tax figures at all. Zero
        // would mean "earned nothing", which is a claim nobody made and which would show a
        // confident RM 0.00 tax bill.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == nil)
    }

    @Test("an override of zero is respected as a real answer")
    func explicitZeroIsRespected() async throws {
        let store = try await StoreFixture.store()
        // Seeded with a real timeline, so this proves an explicit zero beats a *non-zero*
        // derived figure — the sharpest form of the precedence rule.
        try await Self.seedSalary(store, 8_000)
        var facts = try await store.yearFacts(for: 2025)
        facts.grossIncomeOverride = .zero
        try await store.saveYearFacts(facts, for: 2025)
        // A user who genuinely earned nothing this year has said so. That is different
        // from not having told us.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money.zero)
    }

    @Test("a source with no records yet still projects nil, not zero")
    func sourceWithoutRecordsIsUnknown() async throws {
        let store = try await StoreFixture.store()
        // Creating a source and saving its first rate are two writes. Between them the
        // household has named a job and told us nothing about what it pays.
        _ = try await store.save(IncomeSourceDraft(name: "Main job"))
        #expect(try await store.project(year: 2025).snapshot.grossIncome == nil)
    }

    @Test("a timeline that only covers 2025 projects nil for 2024")
    func earlierYearIsUnknown() async throws {
        let store = try await StoreFixture.store()
        try await Self.seedSalary(store, 8_000)
        // Switching the year menu back a year must not report a confident RM 0.00 income
        // for a year the timeline says nothing about.
        #expect(try await store.project(year: 2024).snapshot.grossIncome == nil)
        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money(ringgit: 96_000))
    }

    @Test("a source that ended in a past year projects nil for a later one")
    func endedSourceIsUnknown() async throws {
        let store = try await StoreFixture.store()
        var job = IncomeSourceDraft(name: "Old job")
        job.endedOn = Self.date(2024, 6, 30)
        let sourceID = try await store.save(job)
        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 8_000)
        rate.effectiveFrom = Self.date(2024, 1, 1)
        _ = try await store.save(rate)

        #expect(try await store.project(year: 2024).snapshot.grossIncome == Money(ringgit: 48_000))
        // The source still exists; it just stopped paying before this year began.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == nil)
    }

    @Test("a zero-amount one-off inside the year projects zero, not nil")
    func zeroOneOffIsKnown() async throws {
        let store = try await StoreFixture.store()
        let sourceID = try await store.save(IncomeSourceDraft(name: "Side business"))
        var payment = IncomeRecordDraft(sourceID: sourceID)
        payment.shape = .oneOff
        payment.amount = .zero
        payment.effectiveFrom = Self.date(2025, 5, 1)
        _ = try await store.save(payment)

        // A record dated inside the year says something about the year, even when what it
        // says is RM 0. That is an answer; nil is the absence of one.
        #expect(try await store.project(year: 2025).snapshot.grossIncome == Money.zero)
    }
}
