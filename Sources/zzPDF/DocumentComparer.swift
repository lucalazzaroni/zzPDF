import AppKit
import PDFKit

/// Compares two versions of a document, page by page.
///
/// Text is compared first, because a text change is what a reader usually means by "what
/// changed". Pages whose text matches are then rendered and compared pixel by pixel, which
/// catches moved images, different colours, and edits to pages that carry no text at all.
enum DocumentComparer {
    enum Change: String {
        case identical, textChanged, appearanceChanged, added, removed

        var label: String {
            switch self {
            case .identical: "Unchanged"
            case .textChanged: "Text changed"
            case .appearanceChanged: "Looks different"
            case .added: "Added"
            case .removed: "Removed"
            }
        }

        var symbol: String {
            switch self {
            case .identical: "equal"
            case .textChanged: "text.badge.checkmark"
            case .appearanceChanged: "eye"
            case .added: "plus.circle"
            case .removed: "minus.circle"
            }
        }

        var isChange: Bool { self != .identical }
    }

    struct PageResult: Identifiable {
        let id = UUID()
        let pageNumber: Int
        let change: Change
        /// Share of the page's pixels that differ, for the pages that were rendered.
        let changedFraction: Double
    }

    /// Pixels below this share are treated as rendering noise rather than a real change.
    static let appearanceThreshold = 0.002
    private static let compareDPI: CGFloat = 72

    static func compare(_ original: PDFDocument, with revised: PDFDocument) -> [PageResult] {
        let count = max(original.pageCount, revised.pageCount)
        var results: [PageResult] = []
        for index in 0..<count {
            let left = index < original.pageCount ? original.page(at: index) : nil
            let right = index < revised.pageCount ? revised.page(at: index) : nil
            switch (left, right) {
            case (nil, .some):
                results.append(PageResult(pageNumber: index + 1, change: .added, changedFraction: 1))
            case (.some, nil):
                results.append(PageResult(pageNumber: index + 1, change: .removed, changedFraction: 1))
            case let (.some(a), .some(b)):
                if normalized(a.string) != normalized(b.string) {
                    results.append(PageResult(pageNumber: index + 1, change: .textChanged, changedFraction: 1))
                } else {
                    let fraction = pixelDifference(a, b)
                    results.append(
                        PageResult(
                            pageNumber: index + 1,
                            change: fraction > appearanceThreshold ? .appearanceChanged : .identical,
                            changedFraction: fraction
                        )
                    )
                }
            default:
                break
            }
        }
        return results
    }

    private static func normalized(_ text: String?) -> String {
        (text ?? "")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    static func pixelDifference(_ first: PDFPage, _ second: PDFPage) -> Double {
        guard let a = bitmap(first), let b = bitmap(second) else { return 1 }
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return 1 }
        var differing = 0
        let total = a.pixelsWide * a.pixelsHigh
        guard total > 0 else { return 0 }
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                guard let first = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let second = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(first.redComponent - second.redComponent)
                    + abs(first.greenComponent - second.greenComponent)
                    + abs(first.blueComponent - second.blueComponent)
                if delta > 0.2 { differing += 1 }
            }
        }
        return Double(differing) / Double(total)
    }

    /// The revised page with everything that changed tinted red, for the preview.
    static func differenceImage(_ first: PDFPage?, _ second: PDFPage?) -> NSImage? {
        guard let second else { return first.flatMap { faded($0) } }
        guard let first, let a = bitmap(first), let b = bitmap(second),
              a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else {
            return faded(second)
        }
        guard let output = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: b.pixelsWide,
            pixelsHigh: b.pixelsHigh,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        for y in 0..<b.pixelsHigh {
            for x in 0..<b.pixelsWide {
                guard let before = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let after = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(before.redComponent - after.redComponent)
                    + abs(before.greenComponent - after.greenComponent)
                    + abs(before.blueComponent - after.blueComponent)
                if delta > 0.2 {
                    output.setColor(NSColor(deviceRed: 0.85, green: 0.1, blue: 0.15, alpha: 1), atX: x, y: y)
                } else {
                    let washed = 1 - (1 - after.brightnessComponent) * 0.25
                    output.setColor(NSColor(deviceWhite: washed, alpha: 1), atX: x, y: y)
                }
            }
        }
        let image = NSImage(size: NSSize(width: b.pixelsWide, height: b.pixelsHigh))
        image.addRepresentation(output)
        return image
    }

    private static func faded(_ page: PDFPage) -> NSImage? {
        guard let rendered = OCRTextLayer.render(page, dpi: compareDPI) else { return nil }
        return NSImage(cgImage: rendered.image, size: rendered.pointSize)
    }

    private static func bitmap(_ page: PDFPage) -> NSBitmapImageRep? {
        guard let rendered = OCRTextLayer.render(page, dpi: compareDPI) else { return nil }
        return NSBitmapImageRep(cgImage: rendered.image)
    }
}
