import Foundation
import SwiftData

/// The shipped store shape. Adding, removing or retyping a stored property here is a
/// schema change: bump to `SchemaV2`, add a `MigrationStage`, and never edit V1.
///
/// `SchemaV1` was amended in place once, before first release, to add `IncomeSource` and
/// `IncomeRecord` (Spec §9): with no shipped user, there was no store to migrate, so the
/// bump-and-migrate rule above did not yet apply. It applies from first release onwards —
/// once this schema has shipped, the next change to it must go through `SchemaV2` and a
/// `MigrationStage`, never another in-place edit.
public enum SchemaV1: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        [TaxYear.self,
         Dependent.self,
         ReliefEntry.self,
         Document.self,
         DocumentFile.self,
         ChatMessage.self,
         UserPreferences.self,
         IncomeSource.self,
         IncomeRecord.self]
    }
}
