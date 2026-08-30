import Foundation
import SwiftData

/// The plan existed from the first commit, with a single version and no stages, so the V1
/// store recorded a version to migrate from. Retrofitting a plan later means a shipped
/// store carrying no recorded version, which is a data-loss bug on other people's devices.
/// That foresight is what makes the V1 to V2 stage below a two-line change.
///
/// The stage is lightweight because V2 only adds optional attributes. Nothing is derived
/// from an old column, so there is no `willMigrate` or `didMigrate` to run.
public enum TaxMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self, SchemaV2.self]
    }

    public static var stages: [MigrationStage] {
        [.lightweight(fromVersion: SchemaV1.self, toVersion: SchemaV2.self)]
    }
}
