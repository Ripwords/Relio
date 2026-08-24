import Testing
import Foundation
import SwiftData
import TaxKit
@testable import TaxData

@Suite("Schema and container") struct MigrationTests {

    @Test("SchemaV1 lists every model in the package")
    func schemaIsComplete() {
        let names = Set(SchemaV1.models.map { String(describing: $0) })
        #expect(names == ["TaxYear", "Dependent", "ReliefEntry",
                          "Document", "DocumentFile", "ChatMessage", "UserPreferences"])
    }

    @Test("SchemaV1 is version 1.0.0")
    func schemaVersion() {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("the migration plan names V1 and has no stages yet")
    func migrationPlan() {
        #expect(TaxMigrationPlan.schemas.count == 1)
        #expect(TaxMigrationPlan.stages.isEmpty)
    }

    @Test("every model in the shipped schema is CloudKit-mirroring-safe")
    func shippedSchemaIsMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaV1.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("an in-memory container opens and round-trips a year")
    func inMemoryContainerRoundTrips() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        year.grossIncome = Money(ringgit: 128_000)
        context.insert(year)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaxYear>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.grossIncome == Money(ringgit: 128_000))
    }

    /// This establishes two things nothing else in the suite covers:
    /// 1. `.localOnly` really writes to disk and reads back — the privacy-critical fork
    ///    of whether a user's tax data ever leaves their device depends on this path
    ///    actually persisting locally rather than merely being configured to.
    /// 2. `TaxMigrationPlan` opens a real on-disk store, not only the in-memory one
    ///    every other container test uses.
    ///
    /// A second, independent container is opened at the same URL after the first is
    /// released, so the fetch cannot be served from memory — it must come from disk.
    @Test("a local-only store persists across separate container instances")
    func localOnlyStorePersistsAcrossContainers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TaxDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "store.sqlite")

        do {
            let container = try TaxContainer.make(.localOnly(storeURL))
            let context = ModelContext(container)

            let year = TaxYear(year: 2025)
            year.grossIncome = Money(ringgit: 128_000)
            context.insert(year)
            try context.save()
        }

        let reopened = try TaxContainer.make(.localOnly(storeURL))
        let reopenedContext = ModelContext(reopened)
        let fetched = try reopenedContext.fetch(FetchDescriptor<TaxYear>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.grossIncome == Money(ringgit: 128_000))
    }

    @Test("chat history caps at the most recent 200 messages")
    func chatHistoryCap() {
        #expect(ChatMessage.historyLimit == 200)
    }

    @Test("preferences start with the assistant on and income off")
    func preferenceDefaults() {
        let preferences = UserPreferences()
        // Income is optional per spec §1: a user must be able to log a receipt without
        // entering it. Off by default is what makes the 30-second first launch possible.
        #expect(preferences.incomeModuleEnabled == false)
        #expect(preferences.assistantEnabled == true)
        #expect(preferences.hasCompletedOnboarding == false)
        #expect(preferences.captureQuality == .balanced)
    }
}
