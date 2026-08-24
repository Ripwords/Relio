import Foundation
import SwiftData
import TaxKit

public enum DependentKind: String, Codable, Hashable, Sendable, CaseIterable {
    case child, parent, grandparent
}

/// A dependent's circumstances for one Year of Assessment.
///
/// Stored inline on `Dependent` as a `Codable` value rather than as its own entity:
/// education level and claim share change per YA, but the edit frequency is near zero
/// and keeping it inline holds the CloudKit relationship graph flat. Spec §5.
public struct DependentYearStatus: Codable, Hashable, Sendable {
    public var year: Int
    public var educationLevel: EducationLevel
    /// 100 when claimed in full, 50 when split with a spouse.
    public var claimPercentage: Int
    public var isFullTime: Bool

    public init(year: Int = 0,
                educationLevel: EducationLevel = .none,
                claimPercentage: Int = 100,
                isFullTime: Bool = true) {
        self.year = year
        self.educationLevel = educationLevel
        self.claimPercentage = claimPercentage
        self.isFullTime = isFullTime
    }
}

/// A member of the household a relief can be claimed for.
///
/// Deliberately has no relationship to `TaxYear`. Dependents outlive any one year, and
/// `ReliefEntry` refers to one by `dependentID: UUID` rather than by relationship, which
/// keeps the mirrored graph flat and makes a dangling reference a recoverable data issue
/// rather than a broken object graph.
@Model
public final class Dependent {

    public var id: UUID = UUID()
    public var name: String = ""
    public var dateOfBirth: Date?
    public var kindRaw: String = DependentKind.child.rawValue
    /// Optional on purpose. `false` would mean "confirmed not disabled"; what the app
    /// actually has before it asks is *nothing*. `DependentSnapshot.isDisabled` is
    /// `Bool?` for the same reason, and the engine turns nil into a prompt worth
    /// RM 6,000 rather than a silent ineligibility. Spec §7, three-valued eligibility.
    public var isDisabled: Bool?
    public var yearStatuses: [DependentYearStatus] = []

    public var updatedAt: Date = Date.distantPast
    public var deletedAt: Date?

    public init(id: UUID = UUID(), name: String = "") {
        self.id = id
        self.name = name
    }
}

extension Dependent {

    public var kind: DependentKind {
        get { DependentKind(rawValue: kindRaw) ?? .child }
        set { kindRaw = newValue.rawValue }
    }

    /// The recorded status for a year, or `nil` when nothing has been recorded.
    ///
    /// `nil` rather than a `.none` default on purpose: defaulting would tell the engine
    /// "not in education", which reads as ineligible for the education reliefs. `nil`
    /// reaches the engine as an unanswered question and surfaces as a prompt.
    public func status(for year: Int) -> DependentYearStatus? {
        yearStatuses.first { $0.year == year }
    }

    public var isLive: Bool { deletedAt == nil }
}
