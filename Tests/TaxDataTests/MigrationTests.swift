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
                          "Document", "DocumentFile", "ChatMessage", "UserPreferences",
                          "IncomeSource", "IncomeRecord"])
    }

    /// Pins V1's stored shape property by property, not just its model list.
    ///
    /// `schemaIsComplete` above pins the *names of the models*, which a rename like
    /// `grossIncomeSen` → `grossIncomeOverrideSen` sails straight past. Post-release that
    /// rename drops the old column: SwiftData lightweight-migrates the store, every user's
    /// income figure goes to the default, and the whole suite stays green. Nothing else
    /// here would notice.
    ///
    /// So the expectation below is the shipped contract, and editing it is the bug. If
    /// this test fails, read the message.
    @Test("SchemaV1's attributes are frozen, entity by entity")
    func schemaV1AttributesAreFrozen() {
        // Sorted, exact, and per entity — a superset check would let an added property
        // through, and an added property is a schema change too.
        let expected: [String: [String]] = [
            "ChatMessage": ["createdAt", "deletedAt", "id", "roleRaw", "text", "updatedAt",
                            "year"],
            "Dependent": ["dateOfBirth", "deletedAt", "id", "isDisabled", "kindRaw", "name",
                          "updatedAt", "yearStatuses"],
            "Document": ["deletedAt", "documentDate", "eInvoiceUUID", "id", "kindRaw",
                         "ocrText", "thumbnail", "totalSen", "updatedAt", "vendor"],
            "DocumentFile": ["byteCount", "contentHash", "deletedAt",
                             "downloadProgressPercent", "downloadStateRaw", "id",
                             "updatedAt", "uti"],
            "IncomeRecord": ["amountSen", "deletedAt", "effectiveFrom", "id", "note",
                             "shapeRaw", "updatedAt"],
            "IncomeSource": ["deductsEPF", "deductsSOCSO", "deletedAt", "endedOn", "id",
                             "kindRaw", "name", "updatedAt"],
            "ReliefEntry": ["amountSen", "claimantRaw", "dedupeKey", "deletedAt",
                            "dependentID", "id", "mergedInto", "needsDocument", "note",
                            "reliefCodeRaw", "spentOn", "updatedAt", "vendor"],
            "TaxYear": ["assessmentTypeRaw", "deletedAt", "employmentTypeRaw", "genderRaw",
                        "grossIncomeOverrideSen", "id", "maritalStatusRaw",
                        "propertyPriceSen", "selfIsDisabled", "spouseHasIncome",
                        "spouseIsDisabled", "updatedAt", "year"],
            "UserPreferences": ["accentName", "assistantEnabled", "captureQualityRaw",
                                "deletedAt", "hasCompletedOnboarding", "id",
                                "incomeModuleEnabled", "lastViewedYear", "updatedAt"],
        ]

        // Relationships are stored shape too: renaming one is the same silent data loss.
        let expectedRelationships: [String: [String]] = [
            "ChatMessage": [],
            "Dependent": [],
            "Document": ["entries", "file"],
            "DocumentFile": ["document"],
            "IncomeRecord": ["source"],
            "IncomeSource": ["records"],
            "ReliefEntry": ["documents", "taxYear"],
            "TaxYear": ["entries"],
            "UserPreferences": [],
        ]

        let remedy = """
            SchemaV1 has shipped. Do NOT edit this expectation to match the code: \
            renaming, removing or retyping a stored property drops its column, and the \
            user's data in it, with no error. The remedy is a new `SchemaV2` in \
            Sources/TaxData/Schema/ plus a `MigrationStage` in `TaxMigrationPlan`, \
            leaving `SchemaV1` exactly as it is.
            """

        let entities = Schema(SchemaV1.models).entities
        #expect(Set(entities.map(\.name)) == Set(expected.keys), "\(remedy)")

        for entity in entities.sorted(by: { $0.name < $1.name }) {
            #expect(entity.attributes.map(\.name).sorted() == expected[entity.name],
                    "\(entity.name) attributes changed. \(remedy)")
            #expect(entity.relationships.map(\.name).sorted()
                    == expectedRelationships[entity.name],
                    "\(entity.name) relationships changed. \(remedy)")
        }
    }

    /// The same contract as the V1 test above, for the schema the container now opens.
    ///
    /// V1's test is now blind to one entity. `UserPreferences` is a frozen copy there, so
    /// edits to the live class sail straight past it, and that blind spot grows by an
    /// entity every time a model changes and gets frozen. This test is what keeps watching
    /// the live classes, and the one that will force a `SchemaV3` plus a frozen copy of
    /// today's `UserPreferences` the next time that entity changes.
    @Test("SchemaV2's attributes are frozen, entity by entity")
    func schemaV2AttributesAreFrozen() {
        // Sorted, exact, and per entity. A superset check would let an added property
        // through, and an added property is a schema change too.
        let expected: [String: [String]] = [
            "ChatMessage": ["createdAt", "deletedAt", "id", "roleRaw", "text", "updatedAt",
                            "year"],
            "Dependent": ["dateOfBirth", "deletedAt", "id", "isDisabled", "kindRaw", "name",
                          "updatedAt", "yearStatuses"],
            "Document": ["deletedAt", "documentDate", "eInvoiceUUID", "id", "kindRaw",
                         "ocrText", "thumbnail", "totalSen", "updatedAt", "vendor"],
            "DocumentFile": ["byteCount", "contentHash", "deletedAt",
                             "downloadProgressPercent", "downloadStateRaw", "id",
                             "updatedAt", "uti"],
            "IncomeRecord": ["amountSen", "deletedAt", "effectiveFrom", "id", "note",
                             "shapeRaw", "updatedAt"],
            "IncomeSource": ["deductsEPF", "deductsSOCSO", "deletedAt", "endedOn", "id",
                             "kindRaw", "name", "updatedAt"],
            "ReliefEntry": ["amountSen", "claimantRaw", "dedupeKey", "deletedAt",
                            "dependentID", "id", "mergedInto", "needsDocument", "note",
                            "reliefCodeRaw", "spentOn", "updatedAt", "vendor"],
            "TaxYear": ["assessmentTypeRaw", "deletedAt", "employmentTypeRaw", "genderRaw",
                        "grossIncomeOverrideSen", "id", "maritalStatusRaw",
                        "propertyPriceSen", "selfIsDisabled", "spouseHasIncome",
                        "spouseIsDisabled", "updatedAt", "year"],
            "UserPreferences": ["accentName", "assistantEnabled", "captureQualityRaw",
                                "dateOfBirthRaw", "deletedAt", "hasCompletedOnboarding",
                                "id", "incomeModuleEnabled", "lastViewedYear",
                                "nationalityRaw", "updatedAt"],
        ]

        // Relationships are stored shape too: renaming one is the same silent data loss.
        let expectedRelationships: [String: [String]] = [
            "ChatMessage": [],
            "Dependent": [],
            "Document": ["entries", "file"],
            "DocumentFile": ["document"],
            "IncomeRecord": ["source"],
            "IncomeSource": ["records"],
            "ReliefEntry": ["documents", "taxYear"],
            "TaxYear": ["entries"],
            "UserPreferences": [],
        ]

        let remedy = """
            SchemaV2 is what the container opens. Do NOT edit this expectation to match \
            the code: renaming, removing or retyping a stored property drops its column, \
            and the user's data in it, with no error. The remedy is a frozen copy of the \
            V2 entity nested in `SchemaV2`, the way `SchemaV1` already holds its own, plus \
            a new `SchemaV3` in Sources/TaxData/Schema/ and a further `MigrationStage` in \
            `TaxMigrationPlan`.
            """

        let entities = Schema(SchemaV2.models).entities
        #expect(Set(entities.map(\.name)) == Set(expected.keys), "\(remedy)")

        for entity in entities.sorted(by: { $0.name < $1.name }) {
            #expect(entity.attributes.map(\.name).sorted() == expected[entity.name],
                    "\(entity.name) attributes changed. \(remedy)")
            #expect(entity.relationships.map(\.name).sorted()
                    == expectedRelationships[entity.name],
                    "\(entity.name) relationships changed. \(remedy)")
        }
    }

    @Test("SchemaV1 is version 1.0.0")
    func schemaVersion() {
        #expect(SchemaV1.versionIdentifier == Schema.Version(1, 0, 0))
    }

    @Test("SchemaV2 is version 2.0.0")
    func schemaV2Version() {
        #expect(SchemaV2.versionIdentifier == Schema.Version(2, 0, 0))
    }

    @Test("the migration plan joins V1 to V2 with one lightweight stage")
    func migrationPlan() {
        #expect(TaxMigrationPlan.schemas.count == 2)
        #expect(TaxMigrationPlan.stages.count == 1)

        guard case .lightweight(let from, let to) = TaxMigrationPlan.stages.first else {
            Issue.record("""
                The single stage must be lightweight. A custom stage runs code against \
                every shipped store on migration, which is not what this plan declares.
                """)
            return
        }
        #expect(ObjectIdentifier(from) == ObjectIdentifier(SchemaV1.self))
        #expect(ObjectIdentifier(to) == ObjectIdentifier(SchemaV2.self))
    }

    @Test("every model in the shipped schema is CloudKit-mirroring-safe")
    func shippedSchemaIsMirroringSafe() {
        let problems = SchemaInvariants.violations(in: Schema(SchemaV2.models))
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    @Test("an in-memory container opens and round-trips a year")
    func inMemoryContainerRoundTrips() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        let year = TaxYear(year: 2025)
        year.grossIncomeOverride = Money(ringgit: 128_000)
        context.insert(year)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<TaxYear>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.grossIncomeOverride == Money(ringgit: 128_000))
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
            year.grossIncomeOverride = Money(ringgit: 128_000)
            context.insert(year)
            try context.save()
        }

        let reopened = try TaxContainer.make(.localOnly(storeURL))
        let reopenedContext = ModelContext(reopened)
        let fetched = try reopenedContext.fetch(FetchDescriptor<TaxYear>())

        #expect(fetched.count == 1)
        #expect(fetched.first?.grossIncomeOverride == Money(ringgit: 128_000))
    }

    @Test("a date of birth and a nationality survive a save and fetch")
    func contributionFactsRoundTrip() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        var components = DateComponents()
        components.year = 1965
        components.month = 3
        components.day = 14
        let birthDate = try #require(Calendar(identifier: .gregorian).date(from: components))

        let preferences = UserPreferences()
        preferences.dateOfBirth = birthDate
        preferences.nationalityRaw = "citizen"
        context.insert(preferences)
        try context.save()

        // A second context, so the fetch reaches the store instead of being answered from
        // the inserting context's identity map.
        let fetched = try ModelContext(container).fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.dateOfBirth == birthDate)
        #expect(fetched.first?.dateOfBirthRaw == birthDate)
        #expect(fetched.first?.nationalityRaw == "citizen")
    }

    /// Both facts must read `nil` until someone is asked. A default would be a claim the
    /// user never made, and the EPF rate it implies is the one that overstates relief.
    @Test("preferences nobody was asked read back nil, not a default")
    func contributionFactsAreNotDefaulted() throws {
        let container = try TaxContainer.make(.inMemory)
        let context = ModelContext(container)

        context.insert(UserPreferences())
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<UserPreferences>())
        #expect(fetched.count == 1)
        #expect(fetched.first?.dateOfBirthRaw == nil)
        #expect(fetched.first?.nationalityRaw == nil)
    }

    /// The only check here that opens a real store rather than describing a schema.
    ///
    /// Everything above compares `Schema` objects assembled in memory, which says nothing
    /// about whether SwiftData can carry a V1 store forward. SwiftData does infer the
    /// current delta of two added optional columns on its own, so this does not prove the
    /// stage is what moves it. What it proves is that a store written as V1 opens at V2
    /// with its row and every one of its values intact, which is the claim that fails on a
    /// user's device rather than in CI when a future delta is not inferable.
    @Test("a V1 store on disk opens at V2 with its row intact and the new facts nil")
    func v1StoreMigratesToV2() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "TaxDataTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let storeURL = directory.appending(path: "store.sqlite")
        let identifier = UUID()
        let touchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let removedAt = Date(timeIntervalSince1970: 1_700_086_400)

        do {
            let schema = Schema(versionedSchema: SchemaV1.self)
            let configuration = ModelConfiguration(schema: schema,
                                                   url: storeURL,
                                                   cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: configuration)
            let context = ModelContext(container)

            // Every V1 column is seeded, and seeded away from its default, because a
            // dropped column reads back as its default. Match the default and a rename
            // that silently loses the user's value is indistinguishable from a clean
            // migration, which is the exact failure the pin tables above only describe.
            let preferences = SchemaV1.UserPreferences(id: identifier)
            preferences.accentName = "teal"
            preferences.assistantEnabled = false
            preferences.captureQualityRaw = CaptureQuality.original.rawValue
            preferences.incomeModuleEnabled = true
            preferences.hasCompletedOnboarding = true
            preferences.lastViewedYear = 2024
            preferences.updatedAt = touchedAt
            preferences.deletedAt = removedAt
            context.insert(preferences)
            try context.save()
        }

        let reopened = try TaxContainer.make(.localOnly(storeURL))
        let reopenedContext = ModelContext(reopened)
        let fetched = try reopenedContext.fetch(FetchDescriptor<UserPreferences>())

        #expect(fetched.count == 1)
        let migrated = try #require(fetched.first)
        #expect(migrated.id == identifier)
        #expect(migrated.accentName == "teal")
        #expect(migrated.assistantEnabled == false)
        #expect(migrated.captureQualityRaw == CaptureQuality.original.rawValue)
        #expect(migrated.incomeModuleEnabled == true)
        #expect(migrated.hasCompletedOnboarding == true)
        #expect(migrated.lastViewedYear == 2024)
        #expect(migrated.updatedAt == touchedAt)
        #expect(migrated.deletedAt == removedAt)
        #expect(migrated.dateOfBirthRaw == nil)
        #expect(migrated.nationalityRaw == nil)
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

