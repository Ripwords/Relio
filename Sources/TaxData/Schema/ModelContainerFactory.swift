import Foundation
import SwiftData

/// Builds the one container the app opens.
///
/// Three storages rather than a Bool, because the difference between them is not a
/// toggle: `.inMemory` is for tests, `.localOnly` is what a user signed out of iCloud
/// gets and must be fully functional, and `.cloudKit` is the shipping default. Spec §6
/// requires the app remain usable and account-less offline.
public enum TaxContainer {

    public enum Storage: Sendable {
        case inMemory
        /// `nil` uses SwiftData's default Application Support location.
        case localOnly(URL?)
        /// `nil` uses `.automatic`, which resolves the container from the entitlement.
        case cloudKit(identifier: String?)
    }

    public static func make(_ storage: Storage) throws -> ModelContainer {
        let schema = Schema(versionedSchema: SchemaV2.self)
        let configuration: ModelConfiguration

        switch storage {
        case .inMemory:
            configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)

        case .localOnly(let url):
            if let url {
                configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
            } else {
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
            }

        case .cloudKit(let identifier):
            if let identifier {
                configuration = ModelConfiguration(schema: schema,
                                                   cloudKitDatabase: .private(identifier))
            } else {
                configuration = ModelConfiguration(schema: schema,
                                                   cloudKitDatabase: .automatic)
            }
        }

        return try ModelContainer(for: schema,
                                  migrationPlan: TaxMigrationPlan.self,
                                  configurations: configuration)
    }
}
