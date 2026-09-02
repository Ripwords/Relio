import Testing
import Foundation
import TaxKit
@testable import TaxPresentation

/// The rulebook's `name` is LHDN's own description of a relief, and it is written to be
/// unambiguous rather than short: "Lifestyle — books, computer, smartphone, tablet,
/// internet, courses". That is the right string for a detail screen and the wrong one for
/// a list row or a navigation title, where it wraps to four lines or truncates to
/// "Lifestyle — books, computer, smartp…".
///
/// Short names are editorial copy, not transcribed tax data, so they live here rather than
/// in the rulebook JSON — nothing in `Resources/Rules/` should carry a string LHDN never
/// published. What keeps the two in step is `everyShippedCodeHasAShortName`.
@Suite("Relief short names")
struct ReliefShortNameTests {

    /// The guard that makes the table safe to rely on. `ReliefCode` is a string wrapper
    /// rather than an enum, so a missing entry cannot be a compile error the way the
    /// other switches in `ReliefCopy` are — this test is the substitute for exhaustiveness.
    @Test("every code the generator knows about has a short name")
    func everyShippedCodeHasAShortName() {
        for code in ReliefCode.allGenerated {
            let short = ReliefCopy.shortName(for: code, fullName: "unused")
            #expect(!short.isEmpty, "\(code.rawValue) has no short name")
            #expect(short != "unused", "\(code.rawValue) falls back instead of being named")
        }
    }

    /// A short name earns its place by being shorter. Twenty-eight characters is what fits
    /// on one line of a list row at the default type size on the narrowest iPhone; the
    /// point of the table is to stay under it.
    @Test("short names fit a single line")
    func shortNamesAreShort() {
        for code in ReliefCode.allGenerated {
            let short = ReliefCopy.shortName(for: code, fullName: "")
            #expect(short.count <= 28, "\(code.rawValue) short name is \(short.count) chars: \(short)")
        }
    }

    /// Distinct reliefs must stay distinguishable. Trimming "Medical — serious illness,
    /// fertility treatment, vaccination, dental" down to "Medical" would collide with the
    /// parents' medical relief and with the checkup one, and a list of three rows all
    /// reading "Medical" is worse than the long names it replaced.
    @Test("short names are unique")
    func shortNamesAreUnique() {
        var seen: [String: ReliefCode] = [:]
        for code in ReliefCode.allGenerated {
            let short = ReliefCopy.shortName(for: code, fullName: "")
            if let clash = seen[short] {
                let message = "\(code.rawValue) and \(clash.rawValue) both render as '\(short)'"
                Issue.record(Comment(rawValue: message))
            }
            seen[short] = code
        }
    }

    /// An unknown code still has to render. A rulebook shipped ahead of this table — or a
    /// historical entry whose code was retired — must show LHDN's own name rather than an
    /// empty row.
    @Test("an unmapped code falls back to the rulebook name")
    func unmappedCodeFallsBackToFullName() {
        let unknown = ReliefCode("NOT_A_REAL_RELIEF")
        #expect(ReliefCopy.shortName(for: unknown, fullName: "Some future relief")
                == "Some future relief")
    }
}
