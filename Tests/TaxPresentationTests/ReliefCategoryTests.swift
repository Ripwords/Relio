import Testing
import Foundation
import TaxKit
@testable import TaxPresentation

/// Thirty-two reliefs in one flat list is why the app "has no groupings". The rulebook
/// has no notion of a family — LHDN publishes a list — so the grouping is editorial, and
/// it lives here beside the short names for the same reason: `App/` is outside `swift
/// test`'s reach.
@Suite("Relief categories") struct ReliefCategoryTests {

    /// The guard that makes the table safe to build a colour system on. `ReliefCode` is a
    /// string wrapper, so an unclassified code cannot be a compile error.
    @Test("every relief the generator knows about has a family")
    func everyCodeIsClassified() {
        for code in ReliefCode.allGenerated {
            let category = ReliefCategory(code)
            #expect(category != nil, "\(code.rawValue) belongs to no family")
        }
    }

    /// A family with one relief in it is not a grouping, and a family with twenty is not
    /// either. Both ends are worth pinning: the point of the split is that a reader can
    /// hold the set in their head.
    @Test("no family is empty or overwhelming")
    func familiesAreBalanced() {
        var counts: [ReliefCategory: Int] = [:]
        for code in ReliefCode.allGenerated {
            guard let category = ReliefCategory(code) else { continue }
            counts[category, default: 0] += 1
        }
        #expect(counts.count == ReliefCategory.allCases.count, "a family has no reliefs in it")
        for (category, count) in counts {
            #expect(count <= 9, "\(category) holds \(count) reliefs, too many to scan")
        }
    }

    /// The families are the app's own vocabulary and appear as section headings, so they
    /// need names a person would use, not enum cases.
    @Test("every family has a title and a symbol")
    func familiesArePresentable() {
        for category in ReliefCategory.allCases {
            #expect(!category.title.isEmpty)
            #expect(!category.symbol.isEmpty)
        }
    }

    /// Spot-checks, because a taxonomy that compiles can still be wrong. These are the
    /// ones a Malaysian taxpayer would notice immediately if they landed oddly.
    @Test("the obvious cases land where a taxpayer would look for them")
    func obviousCasesAreRight() {
        #expect(ReliefCategory(.childUnder18) == .children)
        #expect(ReliefCategory(.childcare) == .children)
        #expect(ReliefCategory(.medicalSerious) == .health)
        #expect(ReliefCategory(.parentsMedical) == .health)
        #expect(ReliefCategory(.sspn) == .learning)
        #expect(ReliefCategory(.educationSelf) == .learning)
        #expect(ReliefCategory(.lifestyle) == .living)
        #expect(ReliefCategory(.housingLoanInterest) == .living)
        #expect(ReliefCategory(.epfContribution) == .saving)
        #expect(ReliefCategory(.socsoEis) == .saving)
        #expect(ReliefCategory(.selfAndDependents) == .you)
        #expect(ReliefCategory(.disabledSpouse) == .you)
    }
}
