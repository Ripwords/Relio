import Testing
import Foundation
import TaxKit
@testable import TaxPresentation

@Suite("Formatting discipline") struct FormattingDisciplineTests {

    @Test("the formatter produces the one shape the whole app uses")
    func formatterShape() {
        #expect(Money(ringgit: 2_500).formatted() == "RM 2,500.00")
        #expect(Money.zero.formatted() == "RM 0.00")
        #expect(Money(sen: 5).formatted() == "RM 0.05")
    }

    @Test("editing format is plain digits, not display format")
    func editingFormat() {
        // A text field prefilled with "RM 1,820.50" makes the user delete the prefix
        // before they can type. Display and editing are different jobs.
        #expect(Money(sen: 182_050).formattedForEditing() == "1820.50")
        #expect(Money(sen: 5).formattedForEditing() == "0.05")
    }

    @Test("what the parser writes, the editing formatter reads back")
    func parseFormatRoundTrip() {
        for sen in [0, 1, 99, 100, 182_050, 12_800_000] {
            let money = Money(sen: sen)
            #expect(MoneyParsing.money(from: money.formattedForEditing()) == money)
        }
    }

    @Test("no presentation type builds an amount string by interpolation")
    func noInterpolatedAmounts() throws {
        // Walks the source rather than the runtime: the defect this guards against is a
        // future edit writing "RM \(money.sen / 100)" somewhere, which no behavioural
        // test would catch because it looks right for round numbers.
        //
        // Two roots are walked, not one. The brief that introduced this test predates
        // the SwiftUI views under App/TaxTracker — those views are outside `swift test`
        // entirely (they're an app target, not a package target), so this source walk
        // is the only gate they get. App/TaxTracker also nests into Home/, Reliefs/,
        // Entries/, Onboarding/ and Support/, so this walk recurses; the original
        // Sources/TaxPresentation walk never needed to.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()     // Tests/TaxPresentationTests
            .deletingLastPathComponent()     // Tests
            .deletingLastPathComponent()     // package root

        let roots = [
            packageRoot.appending(path: "Sources/TaxPresentation"),
            packageRoot.appending(path: "App/TaxTracker")
        ]

        let files = try roots.flatMap { try swiftFiles(under: $0) }
        #expect(!files.isEmpty)

        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            for (number, line) in source.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let text = String(line)
                // Flags a display string built by hand: the prefix immediately followed
                // by an interpolation, or the prefix with its trailing space. A bare
                // "RM" with no space is stripping, not building — MoneyParsing does
                // exactly that — so `replacingOccurrences` lines are skipped.
                guard text.contains("RM \\(") || text.contains("\"RM ") else { continue }
                guard !text.contains("replacingOccurrences") else { continue }
                #expect(text.contains("//"),
                        "\(file.lastPathComponent):\(number + 1) builds an RM string by hand — use Money.formatted()")
            }
        }
    }

    /// All `.swift` files under `directory`, recursing into subdirectories.
    private func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            files.append(url)
        }
        return files
    }
}
