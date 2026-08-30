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

    /// Date of birth and nationality class are what set the EPF and SOCSO rates, and
    /// neither can be inferred from a salary figure. The statutory EPF employee share is
    /// 11% below age 60, 0% for a Malaysian citizen aged 60 or over, and 5.5% for a
    /// permanent resident at 60 or over. SOCSO's employee share falls to zero from 55.
    /// Derive EPF relief from salary alone and a 60-year-old citizen is credited with up
    /// to RM4,000 of relief that does not exist, roughly RM960 of tax understated.
    ///
    /// Stored, not asked per year, because each threshold is crossed in a particular month
    /// of a particular year. A year-scoped Bool could express neither which year nor which
    /// month, and would go stale every January.
    ///
    /// This is the most identifying field the app holds, and it syncs through CloudKit
    /// like everything else here. That is a confirmed product decision taken with the
    /// exposure understood, not an oversight. The rates are wrong without it, so do not
    /// "fix" this by dropping the field or by holding it outside the synced store.
    ///
    /// `nil` means "not asked yet", never a default. `IncomeSource.deductsEPF` draws the
    /// same line: defaulting an unanswered question asserts something no user said, and
    /// here the default that looks harmless is the one that overstates relief.
    public var dateOfBirthRaw: Date?

    /// The other half of the rate lookup. At 60 or over a permanent resident still
    /// contributes 5.5% where a citizen contributes nothing, so age alone cannot decide
    /// it. `nil` means "not asked yet", on the same terms as `dateOfBirthRaw`.
    // TODO: the typed `NationalityClass` accessor lands with the contributions unit, which
    // owns that enum. It is deliberately not declared here, so the two units do not both
    // define the same type and collide on merge.
    public var nationalityRaw: String?

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

    /// A passthrough, not a conversion. The `Raw` suffix marks storage that an accessor
    /// owns, so a caller reaching past it is how a wrapper quietly stops being applied.
    /// Giving this one an accessor now keeps every call site off the stored property.
    public var dateOfBirth: Date? {
        get { dateOfBirthRaw }
        set { dateOfBirthRaw = newValue }
    }

    public var isLive: Bool { deletedAt == nil }
}
