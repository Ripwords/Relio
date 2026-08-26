import Foundation
import SwiftData

public enum CaptureQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case compact, balanced, original
}

/// App-wide settings. Logically a singleton, but CloudKit cannot enforce that — two
/// devices first launching offline will each create one. `TaxStore.preferences()`
/// resolves the collision by keeping the newest and soft-deleting the rest, the same
/// rule the reconciliation sweep uses for entries.
@Model
public final class UserPreferences {

    public var id: UUID = UUID()
    /// Named accent from the app's palette, not a serialised colour.
    public var accentName: String = "default"
    public var assistantEnabled: Bool = true
    public var captureQualityRaw: String = CaptureQuality.balanced.rawValue
    /// Income is optional. Off by default is what makes spec §1's 30-second first
    /// launch possible — the app is useful before the user has entered a salary.
    public var incomeModuleEnabled: Bool = false
    public var hasCompletedOnboarding: Bool = false
    /// The year the user was last looking at, so launch resumes where they left off.
    public var lastViewedYear: Int = 0

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID()) {
        self.id = id
    }
}

extension UserPreferences {

    public var captureQuality: CaptureQuality {
        get { CaptureQuality(rawValue: captureQualityRaw) ?? .balanced }
        set { captureQualityRaw = newValue.rawValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
