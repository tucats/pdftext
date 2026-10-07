import Foundation
import PDFKit
import Vision

/// Work for one page, prepared serially (PDFKit isn't thread safe) and then
/// finished concurrently.
enum PageJob: @unchecked Sendable {
    /// The page has usable embedded text; this is its final output.
    case done(String)
    /// The page needs text recognition. `fallback` is any embedded text, used
    /// if recognition finds nothing useful.
    case recognize(RenderedPage, fallback: String)
}

struct PageExtractor {
    let options: Options

    /// Pages with fewer letters and digits than this in their text layer are
    /// treated as scanned. This catches scanner stamps and lone page numbers.
    static let minEmbeddedChars = 20
    /// Recognized pages with fewer confident letters and digits than this are
    /// treated as having no text (graphics or blank pages).
    static let minRecognizedChars = 10
    /// Recognized text below this confidence is ignored when deciding whether
    /// a page has text, since noise in pictures is usually low confidence.
    static let minConfidence: Float = 0.5
    /// Pages with no text and more ink coverage than this are graphics.
    static let graphicInkCoverage = 0.01

    static let graphicMarker = "[GRAPHIC]"

    func prepare(_ page: PDFPage) throws -> PageJob {
        let embedded = Self.embeddedText(of: page)
        if !options.forceOCR && Self.alphanumericCount(embedded) >= Self.minEmbeddedChars {
            return .done(embedded)
        }
        guard let rendered = PageRenderer.render(page, dpi: options.dpi) else {
            throw ExtractionError.renderFailed
        }
        return .recognize(rendered, fallback: embedded)
    }

    func finish(_ job: PageJob) async throws -> String {
        switch job {
        case .done(let text):
            return text
        case .recognize(let rendered, let fallback):
            return try await recognize(rendered, fallback: fallback)
        }
    }

    // MARK: - Text recognition

    private func recognize(_ rendered: RenderedPage, fallback: String) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        // Pin the languages; automatic detection sometimes reads digits and
        // Latin letters as Cyrillic look-alikes.
        request.automaticallyDetectsLanguage = false
        let languages = options.languages.isEmpty ? ["en-US"] : options.languages
        request.recognitionLanguages = languages.map { Locale.Language(identifier: $0) }

        let observations = try await request.perform(on: rendered.image)
        let latinOnly = languages.allSatisfy {
            Locale.Language(identifier: $0).maximalIdentifier.contains("-Latn")
        }

        let width = CGFloat(rendered.image.width)
        let height = CGFloat(rendered.image.height)
        var fragments: [TextLine] = []
        var confidentChars = 0
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            var text = candidate.string.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if latinOnly { text = Self.replacingCyrillicLookalikes(in: text) }
            // Normalized coordinates, origin at the lower left; scale to pixels
            // so widths and heights are comparable.
            let box = observation.boundingBox.cgRect
            let rect = CGRect(x: box.minX * width, y: box.minY * height,
                              width: box.width * width, height: box.height * height)
            fragments.append(TextLine(text: text, rect: rect))
            if candidate.confidence >= Self.minConfidence {
                confidentChars += Self.alphanumericCount(text)
            }
        }

        if confidentChars >= Self.minRecognizedChars {
            return TextLayout.format(TextLayout.rows(from: fragments))
        }
        if rendered.inkCoverage >= Self.graphicInkCoverage {
            return Self.graphicMarker
        }
        // A blank or nearly blank page, perhaps with just a page number.
        return fallback.isEmpty ? TextLayout.format(TextLayout.rows(from: fragments)) : fallback
    }

    /// Vision sometimes returns Cyrillic look-alikes (such as "З" for "3") even
    /// when only Latin-script languages are requested. Map them back.
    private static let cyrillicLookalikes: [Character: Character] = [
        "А": "A", "В": "B", "С": "C", "Е": "E", "Н": "H", "І": "I", "Ј": "J",
        "К": "K", "М": "M", "О": "O", "Р": "P", "Ѕ": "S", "Т": "T", "Х": "X",
        "У": "Y", "З": "3", "И": "N", "Л": "J", "Ь": "b", "а": "a", "с": "c",
        "е": "e", "і": "i", "ј": "j", "к": "k", "м": "m", "о": "o", "п": "n",
        "р": "p", "ѕ": "s", "х": "x", "у": "y", "з": "3", "ь": "b",
    ]

    static func replacingCyrillicLookalikes(in text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x0400...0x04FF).contains($0.value) }) else {
            return text
        }
        return String(text.map { cyrillicLookalikes[$0] ?? $0 })
    }

    // MARK: - Embedded text

    /// Reads the page's text layer in PDFKit's reading order, using each
    /// line's position to restore paragraph breaks and repair PDFKit quirks.
    static func embeddedText(of page: PDFPage) -> String {
        guard let string = page.string as NSString?, string.length > 0 else { return "" }
        // Map page space to the displayed (rotated) orientation so that
        // "up" matches the reader's view.
        let transform = page.transform(for: .cropBox)

        var lines: [TextLine] = []
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: .byLines) { substring, range, _, _ in
            guard var text = substring else { return }
            text = text.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return }
            var rect = CGRect.null
            if let selection = page.selection(for: range) {
                let bounds = selection.bounds(for: page)
                if !bounds.isEmpty { rect = bounds.applying(transform) }
            }
            lines.append(TextLine(text: collapseOverprint(text, range: range, page: page), rect: rect))
        }

        return TextLayout.format(mergeSplitLines(lines))
    }

    /// PDFKit sometimes breaks a line in the middle (often at a curly
    /// apostrophe). Rejoin lines that continue on the same row, without a space
    /// when the pieces touch.
    private static func mergeSplitLines(_ lines: [TextLine]) -> [TextLine] {
        var merged: [TextLine] = []
        for line in lines {
            guard var last = merged.last, !last.rect.isNull, !line.rect.isNull,
                  TextLayout.overlapsVertically(last.rect, line.rect),
                  line.rect.minX >= last.rect.maxX - 1
            else {
                merged.append(line)
                continue
            }
            let charWidth = last.rect.width / CGFloat(max(last.text.count, 1))
            let gap = line.rect.minX - last.rect.maxX
            last.text += (gap < charWidth * 0.15 ? "" : " ") + line.text
            last.rect = last.rect.union(line.rect)
            merged[merged.count - 1] = last
        }
        return merged
    }

    /// Some PDFs fake bold text by drawing it several times at nearly the same
    /// spot, which PDFKit reports as "TitleTitleTitle". If a line is an exact
    /// repetition and each copy starts where the first does, keep one copy.
    private static func collapseOverprint(_ text: String, range: NSRange, page: PDFPage) -> String {
        let length = (text as NSString).length
        for copies in stride(from: min(8, length), through: 2, by: -1) where length % copies == 0 {
            let unit = (text as NSString).substring(to: length / copies)
            guard String(repeating: unit, count: copies) == text else { continue }

            let lineStart = range.location + ((page.string as NSString?)?
                .substring(with: range).prefix(while: \.isWhitespace).utf16.count ?? 0)
            let first = page.characterBounds(at: lineStart)
            let overlaid = (1..<copies).allSatisfy { copy in
                let bounds = page.characterBounds(at: lineStart + copy * (length / copies))
                return abs(bounds.minX - first.minX) < 2 && abs(bounds.minY - first.minY) < 2
            }
            return overlaid ? unit : text
        }
        return text
    }

    static func alphanumericCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(0) { $0 + (CharacterSet.alphanumerics.contains($1) ? 1 : 0) }
    }
}

enum ExtractionError: Error, CustomStringConvertible {
    case renderFailed

    var description: String {
        switch self {
        case .renderFailed: "could not render page"
        }
    }
}
