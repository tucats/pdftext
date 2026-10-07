import CoreGraphics
import Foundation

/// A run of text and where it sits on the page. Rects use a y-up coordinate
/// system (PDF and Vision convention), so larger y values are higher on the page.
struct TextLine {
    var text: String
    var rect: CGRect
}

enum TextLayout {

    /// Joins lines (already in reading order) into page text, inserting blank
    /// lines where the vertical gap between lines is noticeably larger than the
    /// page's normal line spacing.
    static func format(_ lines: [TextLine]) -> String {
        let lineHeight = median(lines.map(\.rect.height).filter { $0 > 0 }) ?? 0
        guard lineHeight > 0 else {
            return lines.map(\.text).joined(separator: "\n")
        }

        // Typical spacing between consecutive lines, so double spaced text
        // doesn't get a blank line after every line.
        var gaps: [CGFloat] = []
        for (prev, line) in zip(lines, lines.dropFirst()) where hasGeometry(prev) && hasGeometry(line) {
            let gap = prev.rect.minY - line.rect.maxY
            if gap >= 0 { gaps.append(gap) }
        }
        let normalGap = min(median(gaps) ?? 0, lineHeight)
        let pitch = lineHeight * 1.2

        var out = ""
        var previous: TextLine?
        for line in lines {
            if let prev = previous {
                var blanks = 0
                if hasGeometry(prev) && hasGeometry(line) {
                    if line.rect.midY > prev.rect.maxY {
                        // Moved back up the page: a new column or text block.
                        blanks = 1
                    } else {
                        let extra = (prev.rect.minY - line.rect.maxY) - normalGap
                        blanks = min(2, max(0, Int(extra / pitch + 0.3)))
                    }
                }
                out += String(repeating: "\n", count: blanks + 1)
            }
            out += line.text
            previous = line
        }
        return out
    }

    /// Groups separately recognized text fragments into rows by vertical
    /// position, then orders the rows top to bottom and each row left to right.
    static func rows(from fragments: [TextLine]) -> [TextLine] {
        var rows: [[TextLine]] = []

        for fragment in fragments.sorted(by: { $0.rect.midY > $1.rect.midY }) {
            // Match against each row's first fragment rather than the row's
            // combined bounds, which would grow and swallow stacked labels.
            // Rows are built top down, so only recent rows can match.
            if let i = rows.indices.suffix(3).last(where: { overlapsVertically(rows[$0][0].rect, fragment.rect) }) {
                rows[i].append(fragment)
            } else {
                rows.append([fragment])
            }
        }

        return rows.map { row in
            let rect = row.dropFirst().reduce(row[0].rect) { $0.union($1.rect) }
            return TextLine(text: joinRow(row), rect: rect)
        }
    }

    /// Joins fragments on one row, using the horizontal gap between them to
    /// decide how many spaces to put in. Fragments that touch are joined with
    /// no space so words aren't split apart.
    private static func joinRow(_ row: [TextLine]) -> String {
        let fragments = row.sorted { $0.rect.minX < $1.rect.minX }
        let widths = fragments.filter { !$0.text.isEmpty }.map { $0.rect.width / CGFloat($0.text.count) }
        let charWidth = max(median(widths) ?? 1, 0.001)

        var text = ""
        var previous: TextLine?
        for fragment in fragments {
            if let prev = previous {
                let gap = fragment.rect.minX - prev.rect.maxX
                // Only fragments that abut are joined without a space;
                // overlapping ones are separate text that happens to collide.
                let touching = gap >= 0 && gap < charWidth * 0.15
                let spaces = touching ? 0 : max(1, Int((gap / charWidth).rounded()))
                text += String(repeating: " ", count: spaces)
            }
            text += fragment.text
            previous = fragment
        }
        return text
    }

    /// True when the two rects share at least half of the taller one's height, so
    /// a tall box (such as sideways text) doesn't pull in everything beside it.
    static func overlapsVertically(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return overlap > 0.5 * max(a.height, b.height)
    }

    private static func hasGeometry(_ line: TextLine) -> Bool {
        !line.rect.isNull && line.rect.height > 0
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
