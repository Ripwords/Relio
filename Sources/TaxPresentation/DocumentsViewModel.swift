import Foundation
import Observation
import TaxKit
import TaxData

/// One claim and the documents LHDN still wants for it.
public struct OutstandingDocument: Hashable, Sendable, Identifiable {
    public var entryID: UUID
    public var code: ReliefCode
    /// The rulebook's full name, kept for the VoiceOver label.
    public var reliefName: String
    public var vendor: String
    public var amount: Money
    public var spentOn: Date?
    /// Every kind this one entry is missing, in `DocumentKind`'s declared order.
    public var kinds: [DocumentKind]

    public var id: UUID { entryID }

    public var shortName: String { ReliefCopy.shortName(for: code, fullName: reliefName) }
}

/// What the Docs tab shows.
///
/// The tab was a placeholder reading "Receipt capture arrives in a later release", and
/// Home's "8 claims need documents" prompt pointed at nothing at all. Capture really is
/// not built — but the requirement checks that decide whether a claim is complete have
/// been built and tested since the first plan, and their answer was reaching no one.
///
/// So this screen does the part that can be done honestly: it names each claim and the
/// document it still needs. That is what someone needs before they go through a drawer or
/// an email archive, and it does not promise an attachment flow that does not exist.
@MainActor
@Observable
public final class DocumentsViewModel {

    public private(set) var outstanding: [OutstandingDocument] = []
    /// What the unsupported claims add up to, as entered. Each claim counted once.
    ///
    /// Deliberately not called "worth": an entry above its relief's cap is allowed less
    /// than it claims, so this is a total rather than a valuation, and the screen says so.
    public private(set) var totalAtRisk: Money = .zero

    public let context: YearContext
    private let store: TaxStore

    public init(context: YearContext, store: TaxStore) {
        self.context = context
        self.store = store
    }

    public func refresh() async {
        guard let result = context.result else {
            outstanding = []
            totalAtRisk = .zero
            return
        }
        let entries = (try? await store.entryDrafts(forYear: context.year)) ?? []
        outstanding = Self.rows(in: result, entries: entries)
        totalAtRisk = Self.totalAtRisk(outstanding)
    }

    /// Pivots the evaluator's per-kind requirements into per-entry rows.
    ///
    /// `RequirementCheck` is shaped the way the engine needs it — one check per document
    /// kind, each naming the entries missing that kind — so an entry missing two kinds
    /// appears in two checks. Rendering that shape directly would show the same receipt
    /// twice, and totalling it would count its money twice.
    static func rows(in result: EvaluationResult,
                     entries: [EntryDraft]) -> [OutstandingDocument] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var kindsByEntry: [UUID: (assessment: ReliefAssessment, kinds: [DocumentKind])] = [:]

        for assessment in result.assessments {
            for requirement in assessment.requirements {
                guard case .missing(let entryIDs) = requirement.status else { continue }
                for id in entryIDs {
                    // An entry the evaluator names but the store no longer holds — deleted
                    // mid-refresh, or arrived from another device — would otherwise render
                    // as a row with no vendor and no amount.
                    guard byID[id] != nil else { continue }
                    kindsByEntry[id, default: (assessment, [])].kinds.append(requirement.kind)
                }
            }
        }

        return kindsByEntry.compactMap { id, pair -> OutstandingDocument? in
            guard let entry = byID[id] else { return nil }
            return OutstandingDocument(
                entryID: id,
                code: pair.assessment.code,
                reliefName: pair.assessment.name,
                vendor: entry.vendor,
                amount: entry.amount,
                spentOn: entry.spentOn,
                // Declared order, so two runs cannot list the same entry's kinds
                // differently — a dictionary gave no order of its own.
                kinds: DocumentKind.allCases.filter(pair.kinds.contains))
        }
        // Biggest claim first: that is the one it costs most to leave unsupported. Ties
        // break on id, because a list that reshuffles between launches reads as a bug —
        // and two receipts for the same amount are common.
        //
        // Spelled out rather than written as one tuple comparison. Descending on the
        // first key and ascending on the second needs the operands crossed in a tuple
        // form, which is correct and reads exactly like a transposition typo.
        .sorted { left, right in
            if left.amount != right.amount { return left.amount > right.amount }
            return left.entryID.uuidString < right.entryID.uuidString
        }
    }

    /// Each claim once, however many documents it is missing.
    static func totalAtRisk(_ rows: [OutstandingDocument]) -> Money {
        rows.reduce(Money.zero) { $0 + $1.amount }
    }
}
