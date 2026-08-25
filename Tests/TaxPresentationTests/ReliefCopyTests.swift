import Testing
import TaxKit
@testable import TaxPresentation

/// `App/` sits outside `swift test`'s reach, so these 19 strings had zero coverage while
/// they lived in the view. Both switches in `ReliefCopy` are exhaustive with no `default`,
/// so a rulebook adding a case is a compile error here rather than a silent misrender —
/// these tests exist to catch the remaining way copy can go wrong: a blank or duplicated
/// string that compiles fine but reads wrong on screen.
@Suite("ReliefCopy") struct ReliefCopyTests {

    @Test("every ProfileQuestion maps to a non-empty string")
    func profileQuestionsAreNonEmpty() {
        for question in ProfileQuestion.allCases {
            #expect(!ReliefCopy.text(for: question).isEmpty)
        }
    }

    @Test("every ProfileQuestion maps to a distinct string")
    func profileQuestionsAreDistinct() {
        let strings = ProfileQuestion.allCases.map { ReliefCopy.text(for: $0) }
        #expect(Set(strings).count == ProfileQuestion.allCases.count)
    }

    @Test("every DocumentKind maps to a non-empty string")
    func documentKindsAreNonEmpty() {
        for kind in DocumentKind.allCases {
            #expect(!ReliefCopy.text(for: kind).isEmpty)
        }
    }

    @Test("every DocumentKind maps to a distinct string")
    func documentKindsAreDistinct() {
        let strings = DocumentKind.allCases.map { ReliefCopy.text(for: $0) }
        #expect(Set(strings).count == DocumentKind.allCases.count)
    }
}
