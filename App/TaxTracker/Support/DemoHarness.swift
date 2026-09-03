#if DEBUG
import Foundation
import TaxKit
import TaxData

/// Deterministic app state, driven by launch arguments, so any screen can be put on
/// screen and photographed without touching the device.
///
/// Why this exists: this machine has no simulator tap automation — `simctl` installs,
/// launches and screenshots, and that is all. Without a way in, the only screen that can
/// ever be reviewed is the first one a fresh install shows, which is onboarding. Seeding
/// a known profile and opening straight onto a named screen turns "look at the Reliefs
/// list" into one command, which is what makes an unattended UI pass possible at all.
///
/// `#if DEBUG` and a launch argument, both: the argument keeps it inert in a normal run,
/// and the compile guard keeps the seeding code itself out of a shipping binary.
enum DemoHarness {

    /// Seed a profile before the first read. Off unless asked for.
    static var wantsSeed: Bool { arguments.contains("-relio-demo") }

    /// Complete onboarding and seed nothing, which is the state every real user is in the
    /// moment they finish the welcome flow. Every empty state in the app lives here and
    /// nothing else could reach it: `-relio-demo` fills the app up, and a fresh install
    /// stops at onboarding.
    static var wantsEmpty: Bool { arguments.contains("-relio-empty") }

    /// Seed the household *and* answer every question it leaves open, which is the state
    /// a diligent user reaches and the only one where Home has no prompts at all. It had
    /// never been looked at.
    static var wantsComplete: Bool { arguments.contains("-relio-complete") }

    /// Force the welcome flow even though the seeded profile has completed it, so
    /// onboarding stays reviewable after seeding.
    static var wantsOnboarding: Bool { arguments.contains("-relio-onboarding") }

    /// The screen to open on top of Home, as `-relio-screen <name>`.
    ///
    /// Names rather than a `Route` value because the caller is a shell script. `relief:`
    /// carries the code after the colon, which is the only one that needs a payload.
    static var screen: String? { value(after: "-relio-screen") }

    /// The year to open on, as `-relio-year 2023`. Year switching is a core flow with no
    /// other way to reach it from a screenshot run.
    static var year: Int? { value(after: "-relio-year").flatMap(Int.init) }

    private static var arguments: [String] { ProcessInfo.processInfo.arguments }

    private static func value(after flag: String) -> String? {
        guard let index = arguments.firstIndex(of: flag),
              arguments.index(after: index) < arguments.endIndex else { return nil }
        return arguments[arguments.index(after: index)]
    }

    /// The household the README's worked example describes: married, one non-earning
    /// spouse, three children, a first home — on a salary that rises mid-year, because a
    /// flat salary never exercises the income timeline's blending.
    ///
    /// Two facts are deliberately left unanswered. `propertyPrice` and `spouseIsDisabled`
    /// are what make Home show its "answer N questions" prompt, and that prompt is the
    /// thing being worked on. A fully answered profile would hide it.
    /// Marks onboarding done and writes nothing else.
    static func markOnboarded(_ store: TaxStore, year: Int) async {
        do {
            var preferences = try await store.preferences()
            preferences.hasCompletedOnboarding = true
            preferences.lastViewedYear = year
            try await store.savePreferences(preferences)
        } catch {
            print("[DemoHarness] could not mark onboarded: \(error)")
        }
    }

    static func seed(into store: TaxStore, year: Int) async {
        do {
            var facts = YearFacts()
            facts.maritalStatus = .married
            facts.spouseHasIncome = false
            facts.assessmentType = .separate
            facts.employmentType = .privateSector
            facts.gender = .female
            if wantsComplete {
                // The three the seed deliberately leaves open, so Home's prompt row has
                // something to show. Answered, Home should have no prompts at all.
                facts.selfIsDisabled = false
                facts.spouseIsDisabled = false
                facts.propertyPrice = Money(ringgit: 450_000)
            }
            try await store.saveYearFacts(facts, for: year)

            let employment = try await store.seedPrimaryEmployment(
                name: "Petronas Digital",
                monthlyRate: Money(ringgit: 10_000),
                effectiveFrom: date(year, 1, 1))

            let raise = IncomeRecordDraft(
                id: DemoID.raise,
                sourceID: employment,
                shape: .recurring,
                amount: Money(ringgit: 11_500),
                effectiveFrom: date(year, 4, 1),
                note: "Annual review")
            try await store.save(raise)

            for child in demoChildren(year: year) {
                try await store.save(child)
            }

            for draft in demoEntries(year: year) {
                try await store.save(draft)
            }

            var preferences = try await store.preferences()
            preferences.hasCompletedOnboarding = !wantsOnboarding
            preferences.incomeModuleEnabled = true
            preferences.lastViewedYear = year
            try await store.savePreferences(preferences)
        } catch {
            // A seed that fails leaves the app on whatever state it already had, which is
            // still a usable screenshot. Printing beats trapping: the run script tails the
            // log, and a crash here would look like an app bug.
            print("[DemoHarness] seed failed: \(error)")
        }
    }

    private static func demoChildren(year: Int) -> [DependentDraft] {
        [
            DependentDraft(id: DemoID.child(1),
                           name: "Aisyah",
                           kind: .child,
                           dateOfBirth: date(year - 20, 3, 14),
                           isDisabled: false,
                           yearStatuses: [DependentYearStatus(year: year,
                                                              educationLevel: .tertiaryLocal,
                                                              claimPercentage: 100,
                                                              isFullTime: true)]),
            DependentDraft(id: DemoID.child(2),
                           name: "Danial",
                           kind: .child,
                           dateOfBirth: date(year - 14, 9, 2),
                           isDisabled: false,
                           yearStatuses: [DependentYearStatus(year: year,
                                                              educationLevel: .preTertiary,
                                                              claimPercentage: 100,
                                                              isFullTime: true)]),
            DependentDraft(id: DemoID.child(3),
                           name: "Zara",
                           kind: .child,
                           dateOfBirth: date(year - 5, 6, 21),
                           isDisabled: false,
                           yearStatuses: [DependentYearStatus(year: year,
                                                              educationLevel: .none,
                                                              claimPercentage: 100,
                                                              isFullTime: false)]),
        ]
    }

    /// Deliberately uneven: some reliefs full, some part-used, most untouched. A profile
    /// where every relief is half spent makes every progress bar look the same and hides
    /// exactly the ordering bugs this list is meant to show.
    private static func demoEntries(year: Int) -> [EntryDraft] {
        [
            (ReliefCode.lifestyle, 1_700, "Kinokuniya", 2, 11),
            (ReliefCode.medicalSerious, 2_100, "Pantai Hospital", 5, 3),
            (ReliefCode.sspn, 2_000, "SSPN-i Plus", 1, 20),
            (ReliefCode.lifeInsurance, 3_000, "Great Eastern", 1, 15),
            (ReliefCode.educationSelf, 1_200, "Coursera", 7, 8),
            (ReliefCode.medicalCheckup, 400, "BP Healthcare", 9, 12),
            (ReliefCode.lifestyleSports, 500, "Decathlon", 3, 27),
            (ReliefCode.childcare, 2_400, "Little Caliphs", 4, 6),
            // Deliberately a relief whose cap moved between YA2024 and YA2025, so the
            // Compare screen's priced lines have something to price. Without one, every
            // seeded run showed only its "other changes" half.
            (ReliefCode.insuranceEduMedical, 3_500, "AIA Medical", 6, 18),
        ].enumerated().map { index, row in
            let (code, ringgit, vendor, month, day) = row
            return EntryDraft(id: DemoID.entry(index),
                              year: year,
                              code: code,
                              amount: Money(ringgit: Decimal(ringgit)),
                              vendor: vendor,
                              spentOn: date(year, month, day))
        }
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Kuala_Lumpur") ?? .gmt
        return calendar.date(from: components) ?? .distantPast
    }
}

/// Fixed identities so re-running the seed updates the same rows rather than stacking
/// duplicates on top of them. The `5E1D` prefix ("seed") makes a seeded row recognisable
/// on sight in a database dump.
///
/// The store's own `WellKnownID` is internal to TaxData, so these cannot join it; the one
/// identity shared with it — the employment source — is taken from the value
/// `seedPrimaryEmployment` returns rather than reconstructed here.
private enum DemoID {

    static let raise = UUID(uuidString: "5E1D0000-0000-4000-A000-000000000001")!

    static func child(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5E1D0000-0000-4000-A000-0000000001%02d", n))!
    }

    static func entry(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "5E1D0000-0000-4000-A000-0000000002%02d", n))!
    }
}
#endif
