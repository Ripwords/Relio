import Foundation
import SwiftData

extension SchemaV1 {

    /// V1's `UserPreferences` as it actually shipped, pinned here so it can never drift.
    ///
    /// `SchemaV1.models` used to name the live `UserPreferences` class, which meant the
    /// "frozen" V1 record was really a mirror of whatever the live model had since become.
    /// Every later edit to the live class silently rewrote history: V1 claimed to describe
    /// the store on a user's device while describing the store the current code would
    /// create. A migration stage computed from that is a stage from the wrong shape.
    ///
    /// This copy is the real V1 shape. It is never edited, it has no relationships and no
    /// typed accessors, and nothing but migration reads it, so there is no reason for a
    /// feature to touch it. Every other entity gets this same treatment the first time its
    /// shape changes; `MigrationTests.schemaV1AttributesAreFrozen` is what forces the copy
    /// rather than leaving it to whoever remembers.
    @Model
    public final class UserPreferences {

        public var id: UUID = UUID()
        public var accentName: String = "default"
        public var assistantEnabled: Bool = true
        public var captureQualityRaw: String = CaptureQuality.balanced.rawValue
        public var incomeModuleEnabled: Bool = false
        public var hasCompletedOnboarding: Bool = false
        public var lastViewedYear: Int = 0

        public var updatedAt: Date = Date.distantPast
        public var deletedAt: Date?

        public init(id: UUID = UUID()) {
            self.id = id
        }
    }
}
