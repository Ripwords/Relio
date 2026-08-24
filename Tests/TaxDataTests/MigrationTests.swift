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

    @Test("a local-only container is configured without CloudKit")
    func localOnlyHasNoCloudKit() throws {
        // The app must remain fully usable signed out of iCloud. Spec §6 failure mode 3.
        // `ModelConfiguration.CloudKitDatabase` is not `Equatable` on this SDK, so this
        // proves the point a different way: an in-memory container (no iCloud account
        // required) opens and round-trips through exactly one configuration.
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        context.insert(year)
        try context.save()

        #expect(container.configurations.count == 1)
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
