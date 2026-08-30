import Foundation
import SwiftData

/// The shipped store shape from V2 onwards.
///
/// V2 adds `dateOfBirthRaw` and `nationalityRaw` to `UserPreferences`, because Malaysia's
/// EPF and SOCSO employee rates step down at fixed ages and differ for a permanent
/// resident, so relief derived from salary alone is wrong for anyone past those ages.
///
/// The stage is lightweight: both attributes are optional, so every existing row gains
/// two columns that read `nil`, and nothing has to be computed or backfilled. `nil` is
/// also the correct value for those rows, since nobody has been asked yet.
///
/// The nine entities are V1's, in V1's order. `UserPreferences` here is the live class;
/// V1 names its frozen copy instead, which is the only difference between the two lists.
public enum SchemaV2: VersionedSchema {

    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

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
