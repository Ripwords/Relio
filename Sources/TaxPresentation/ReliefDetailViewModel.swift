import Foundation
import Observation
import TaxKit
import TaxData

@MainActor
@Observable
public final class ReliefDetailViewModel {

    public let code: ReliefCode
    public private(set) var assessment: ReliefAssessment?
    public private(set) var entries: [EntryDraft] = []
    public private(set) var subLimits: [ReliefAssessment] = []
    public private(set) var requirements: [RequirementCheck] = []
    public private(set) var sourceURL: URL?
    public private(set) var notes: String?

    private let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore, code: ReliefCode) {
        self.context = context
        self.store = store
        self.code = code
    }

    public func refresh() async {
        guard let found = context.result?.assessment(for: code) else {
            assessment = nil
            entries = []
            subLimits = []
            requirements = []
            sourceURL = nil
            notes = nil
            return
        }

        assessment = found
        subLimits = found.children
        requirements = found.requirements
        sourceURL = found.sourceURL
        notes = found.notes

        // A sub-limit's entries belong to it, not to the parent, so the parent screen
        // lists only its own — the children are rendered as their own rows.
        let all = (try? await store.entryDrafts(forYear: context.year)) ?? []
        entries = all
            .filter { $0.code == code }
            .sorted { left, right in
                if left.spentOn != right.spentOn {
                    return (left.spentOn ?? .distantPast) > (right.spentOn ?? .distantPast)
                }
                return left.id.uuidString < right.id.uuidString
            }
    }
}
