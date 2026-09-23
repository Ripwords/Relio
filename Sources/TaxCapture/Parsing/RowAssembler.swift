import Foundation

/// One piece of text as the recogniser returned it, before rows are rebuilt.
public struct TextFragment: Hashable, Sendable {
    public var text: String
    public var page: Int
    /// 0 to 1 across the page.
    public var left: Double
    /// 0 to 1 down the page — top-origin, already flipped from Vision's bottom-left.
    public var top: Double
    public var bottom: Double
    public var confidence: Double

    public init(text: String, page: Int, left: Double, top: Double,
                bottom: Double, confidence: Double) {
        self.text = text
        self.page = page
        self.left = left
        self.top = top
        self.bottom = bottom
        self.confidence = confidence
    }
}

/// Rebuilds printed rows from fragments.
///
/// A till receipt puts the label at the left margin and the amount at the right, and
/// Vision often returns them as two observations. Two fragments share a row when their
/// vertical centres are within half the smaller one's height.
public enum RowAssembler {

    public static func lines(from fragments: [TextFragment]) -> [OCRLine] {
        struct Row {
            var page: Int
            var top: Double
            var bottom: Double
            var members: [TextFragment]
        }

        var rows: [Row] = []
        let ordered = fragments.sorted { ($0.page, $0.top, $0.left) < ($1.page, $1.top, $1.left) }
        for fragment in ordered {
            let centre = (fragment.top + fragment.bottom) / 2
            let height = fragment.bottom - fragment.top
            // The row keeps its first fragment's band, so a long row cannot drift down
            // the page one slightly-lower fragment at a time.
            if let index = rows.lastIndex(where: { row in
                row.page == fragment.page
                    && abs((row.top + row.bottom) / 2 - centre)
                        <= min(row.bottom - row.top, height) / 2
            }) {
                rows[index].members.append(fragment)
            } else {
                rows.append(Row(page: fragment.page, top: fragment.top,
                                bottom: fragment.bottom, members: [fragment]))
            }
        }

        return rows
            .sorted { ($0.page, $0.top) < ($1.page, $1.top) }
            .map { row in
                let members = row.members.sorted { $0.left < $1.left }
                return OCRLine(text: members.map(\.text).joined(separator: " "),
                               page: row.page,
                               top: row.top,
                               confidence: members.map(\.confidence).min() ?? 0)
            }
    }
}
