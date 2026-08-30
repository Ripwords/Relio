import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

/// Builders for the contribution store suites.
private enum ProfileFixture {

    static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur")!
        return calendar.date(from: components)!
    }

    /// A wage high enough that 11% of it clears the RM4,000 EPF relief cap over a year.
    static func seedSalariedJob(_ store: TaxStore) async throws {
        var job = IncomeSourceDraft(name: "Main job")
        job.deductsEPF = true
        let sourceID = try await store.save(job)

        var rate = IncomeRecordDraft(sourceID: sourceID)
        rate.amount = Money(ringgit: 5_000)
        rate.effectiveFrom = date(2024, 1, 1)
        _ = try await store.save(rate)
    }

    static let answeredProfile = ContributorProfile(dateOfBirth: date(1990, 3, 12),
                                                    nationality: .malaysianCitizen)
}

@Suite("Nationality accessor") struct NationalityAccessorTests {

    @Test("a raw value no case matches reads as nil rather than trapping")
    func unreadableRawDegradesToNil() {
        let row = UserPreferences()
        // CloudKit writes this column, and an older build of the enum is one schema
        // migration away from being asked to read a case it has never heard of.
        row.nationalityRaw = "resident_of_mars"
        #expect(row.nationality == nil)
    }

    @Test("every case round-trips through the raw column")
    func everyCaseRoundTrips() {
        for nationality in NationalityClass.allCases {
            let row = UserPreferences()
            row.nationality = nationality
            #expect(row.nationality == nationality)
            #expect(row.nationalityRaw == nationality.rawValue)
        }
    }

    @Test("an unwritten column reads as not asked yet")
    func nilRawIsNil() {
        let row = UserPreferences()
        #expect(row.nationalityRaw == nil)
        #expect(row.nationality == nil)

        row.nationality = .malaysianCitizen
        row.nationality = nil
        #expect(row.nationalityRaw == nil)
    }
}

@Suite("Contributor profile store") struct ContributorProfileStoreTests {

    @Test("a profile round-trips, both halves and either half alone")
    func profileRoundTrips() async throws {
        let store = try await StoreFixture.store()
        #expect(try await store.contributorProfile() == ContributorProfile())

        try await store.saveContributorProfile(ProfileFixture.answeredProfile)
        #expect(try await store.contributorProfile() == ProfileFixture.answeredProfile)

        // Half an answer is a real state: the sheet asks two questions and the user can
        // close it after one.
        let ageOnly = ContributorProfile(dateOfBirth: ProfileFixture.date(1990, 3, 12))
        try await store.saveContributorProfile(ageOnly)
        #expect(try await store.contributorProfile() == ageOnly)

        try await store.saveContributorProfile(ContributorProfile())
        #expect(try await store.contributorProfile() == ContributorProfile())
    }

    @Test("the profile and the settings never overwrite each other")
    func writesAreDisjoint() async throws {
        let store = try await StoreFixture.store()

        var settings = PreferencesSnapshot()
        settings.accentName = "teal"
        settings.hasCompletedOnboarding = true
        settings.lastViewedYear = 2024
        try await store.savePreferences(settings)
        try await store.saveContributorProfile(ProfileFixture.answeredProfile)

        // A profile save must not null a settings answer.
        #expect(try await store.preferences() == settings)

        settings.accentName = "amber"
        try await store.savePreferences(settings)

        // And a settings save must not null a profile answer. Both rows are the same
        // CloudKit-synced singleton, so one write clobbering the other's fields would look
        // to the user like an answer they gave silently reverting to unasked.
        #expect(try await store.contributorProfile() == ProfileFixture.answeredProfile)
        #expect(try await store.preferences().accentName == "amber")
    }
}

@Suite("Contribution estimate reads") struct ContributionEstimateReadTests {

    @Test("the estimate is the derivation over this store's own profile and income")
    func estimateMatchesItsInputs() async throws {
        let store = try await StoreFixture.store()
        try await ProfileFixture.seedSalariedJob(store)
        try await store.saveContributorProfile(ProfileFixture.answeredProfile)

        let estimate = try await store.contributionEstimate(scheme: .employeesProvidentFund,
                                                            year: 2025)
        #expect(estimate == ContributionDerivation.estimate(
            scheme: .employeesProvidentFund, year: 2025,
            from: try await store.incomeSnapshots(),
            profile: try await store.contributorProfile()))
        #expect(estimate.certainty(against: Money(ringgit: 4_000))
                == .exactlyTheCap(Money(ringgit: 4_000)))
    }

    @Test("clearing the stored nationality blocks the estimate")
    func estimateTracksTheStoredProfile() async throws {
        let store = try await StoreFixture.store()
        try await ProfileFixture.seedSalariedJob(store)
        try await store.saveContributorProfile(ProfileFixture.answeredProfile)

        // The profile is genuinely read from storage rather than defaulted: take the
        // nationality away and the same records prove nothing, because the admissible
        // contributors now include a citizen aged 60 or over who contributes 0%.
        try await store.saveContributorProfile(
            ContributorProfile(dateOfBirth: ProfileFixture.date(1990, 3, 12)))

        let estimate = try await store.contributionEstimate(scheme: .employeesProvidentFund,
                                                            year: 2025)
        #expect(estimate.certainty(against: Money(ringgit: 4_000))
                == .blocked(missing: [.nationality]))
    }
}
