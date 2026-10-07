import CoreGraphics
import PDFKit

/// A page rendered to a grayscale bitmap for text recognition.
struct RenderedPage: @unchecked Sendable {
    let image: CGImage
    /// Fraction of the page covered by dark pixels; used to tell blank pages
    /// from graphics when no text is found.
    let inkCoverage: Double
}

enum PageRenderer {
    /// Keeps very large pages (posters, drawings) from producing huge bitmaps.
    static let maxPixelDimension = 8000.0

    static func render(_ page: PDFPage, dpi: Double) -> RenderedPage? {
        let box = page.bounds(for: .cropBox)
        let rotated = page.rotation % 180 != 0
        let pageSize = rotated
            ? CGSize(width: box.height, height: box.width)
            : box.size

        var scale = dpi / 72
        scale = min(scale, maxPixelDimension / max(pageSize.width, pageSize.height, 1))
        let width = Int((pageSize.width * scale).rounded())
        let height = Int((pageSize.height * scale).rounded())
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else { return nil }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        // draw(with:to:) applies the page's rotation and crop box offset.
        page.draw(with: .cropBox, to: context)

        guard let image = context.makeImage() else { return nil }
        return RenderedPage(image: image, inkCoverage: inkCoverage(of: context))
    }

    /// Samples the bitmap to estimate how much of it is non-background.
    private static func inkCoverage(of context: CGContext) -> Double {
        guard let data = context.data else { return 0 }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let step = 4
        var dark = 0
        var total = 0
        for y in stride(from: 0, to: context.height, by: step) {
            let row = pixels + y * context.bytesPerRow
            for x in stride(from: 0, to: context.width, by: step) {
                if row[x] < 160 { dark += 1 }
                total += 1
            }
        }
        return total > 0 ? Double(dark) / Double(total) : 0
    }
}
