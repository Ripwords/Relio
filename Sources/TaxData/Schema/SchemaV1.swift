import Foundation
import SwiftData

/// The shipped store shape.
///
/// `SchemaV1` was amended in place before first release: to add `IncomeSource` and
/// `IncomeRecord` (Spec §9), and to replace `TaxYear`'s gross-income and
/// statutory-deduction fields with `grossIncomeOverrideSen` (Spec §6). With no shipped
/// user, there was no store to migrate, so the rule below did not yet apply. That
/// exception is spent: it covered the pre-release window only.
///
/// From first release onwards: adding, removing or retyping a stored property here is a
/// schema change. Bump to `SchemaV2`, add a `MigrationStage`, and never edit V1. An
/// in-place rename drops the old column and silently loses every user's data in it, which
/// is why `MigrationTests.schemaV1AttributesAreFrozen` pins this entity list attribute by
/// attribute rather than trusting this comment.
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
