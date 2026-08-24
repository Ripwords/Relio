import Foundation
import SwiftData

/// One version, no stages — deliberately. The plan exists from the first commit so the
/// V1 store records a version to migrate from. Retrofitting one later means a shipped
/// store with no recorded version, which is a data-loss bug on other people's devices.
public enum TaxMigrationPlan: SchemaMigrationPlan {

    public static var schemas: [any VersionedSchema.Type] {
        [SchemaV1.self]
    }

    public static var stages: [MigrationStage] {
        []
    }
}
