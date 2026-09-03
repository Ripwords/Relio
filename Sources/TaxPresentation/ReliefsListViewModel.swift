import Foundation
import Observation
import TaxKit
import TaxData

public enum ReliefRowState: Hashable, Sendable {
    case needsAnswer
    case claimable
    case exhausted
    /// Eligible, counted once per dependant, and no dependant recorded — so its cap is
    /// zero and there is nothing to claim against yet.
    ///
    /// Distinct from `unavailable`, which is a statement about the user: this relief does
    /// not apply to you. For a parent who has simply not entered their children that is
    /// false, and it is the discouraging kind of false — it says do not bother with the
    /// one action that would unlock RM 2,000 a child.
    case needsDependent
    case unavailable
}

public struct ReliefRow: Hashable, Sendable, Identifiable {
    public var code: ReliefCode
    public var name: String
    public var cap: Money
    public var allowed: Money
    public var headroom: Money
    public var usedPercent: Int
    public var state: ReliefRowState

    /// What a row shows. `name` is LHDN's full description and stays the accessibility
    /// label, where length costs nothing and precision is worth having.
    public var shortName: String { ReliefCopy.shortName(for: code, fullName: name) }

    public var id: ReliefCode { code }
}

public struct ReliefSection: Hashable, Sendable, Identifiable {
    public var title: String
    public var rows: [ReliefRow]
    public var id: String { title }
}

@MainActor
@Observable
public final class ReliefsListViewModel {

    public let context: YearContext
    public var searchText: String = ""
    public private(set) var sections: [ReliefSection] = []

    public init(context: YearContext) {
        self.context = context
    }

    /// Fixed section order, chosen so the two groups the user can act on come first.
    /// Alphabetical order would bury them.
    private static let sectionOrder: [(String, ReliefRowState)] = [
        ("Needs an answer", .needsAnswer),
        ("Add a dependant to claim these", .needsDependent),
        ("Still claimable", .claimable),
        ("Fully claimed", .exhausted),
        ("Not applicable to you", .unavailable)
    ]

    public func refresh() {
        guard let result = context.result else {
            sections = []
            return
        }

        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let rows = result.assessments
            // The short name is searched too, because it is the only name on screen: a
            // user who reads "Serious medical" in the list and types it back would
            // otherwise get no results, LHDN's own name being "Medical — serious illness,
            // fertility treatment, vaccination, dental".
            .filter { needle.isEmpty
                || $0.name.lowercased().contains(needle)
                || ReliefCopy.shortName(for: $0.code, fullName: $0.name)
                    .lowercased().contains(needle)
                || $0.code.rawValue.lowercased().contains(needle) }
            .map { assessment in
                Self.row(from: assessment,
                         isPerDependent: Self.isPerDependent(context.rule(for: assessment.code)))
            }

        sections = Self.sectionOrder.compactMap { title, state in
            let matching = rows
                .filter { $0.state == state }
                .sorted { left, right in
                    if left.headroom != right.headroom { return left.headroom > right.headroom }
                    return left.code.rawValue < right.code.rawValue
                }
            return matching.isEmpty ? nil : ReliefSection(title: title, rows: matching)
        }
    }

    /// Whether a rule's ceiling is counted once per dependant. See `ReliefRowState`.
    static func isPerDependent(_ rule: ReliefRule?) -> Bool {
        guard case .perDependent = rule?.cap else { return false }
        return true
    }

    static func row(from assessment: ReliefAssessment,
                    isPerDependent: Bool = false) -> ReliefRow {
        let state: ReliefRowState
        switch assessment.eligibility {
        case .ineligible:
            state = .unavailable
        case .needsInfo:
            state = .needsAnswer
        case .eligible where assessment.cap == .zero:
            // A cap of zero is not a relief that has been used up. It is one there is
            // nothing to claim against yet — a per-dependent relief with no dependants
            // recorded is exactly this, and CHILD_UNDER_18 sat in "Fully claimed"
            // telling a user with no children on file that they had used all of it.
            //
            // Nor is it "not applicable to you", which is a claim about the user that
            // nobody has established. `isPerDependent` separates the two.
            state = isPerDependent ? .needsDependent : .unavailable
        case .eligible:
            state = assessment.headroom > .zero ? .claimable : .exhausted
        }

        return ReliefRow(code: assessment.code,
                         name: assessment.name,
                         cap: assessment.cap,
                         allowed: assessment.allowed,
                         headroom: assessment.headroom,
                         usedPercent: HomeViewModel.percentUsed(assessment),
                         state: state)
    }
}
