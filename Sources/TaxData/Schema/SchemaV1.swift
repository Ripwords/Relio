import Foundation
import SwiftData

/// The shipped store shape. Adding, removing or retyping a stored property here is a
/// schema change: bump to `SchemaV2`, add a `MigrationStage`, and never edit V1.
public enum SchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [TaxYear.self,
         Dependent.self,
         ReliefEntry.self,
         Document.self,
         DocumentFile.self,
         ChatMessage.self,
         UserPreferences.self]
    }
}
