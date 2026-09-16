import AppKit
import PDFKit

/// Geometry of the free-text layout used by PDFKit, measured against its own renderer.
/// PDFKit places the first baseline at `ceil(ascender) + 3` below the top edge of the
/// annotation and starts the glyphs 2 points after its left edge.
enum FreeTextLayout {
    static let horizontalInset: CGFloat = 2
    static let topPadding: CGFloat = 3

    static func firstBaselineInset(for font: NSFont) -> CGFloat {
        ceil(font.ascender) + topPadding
    }

    static func topEdge(forBaseline baseline: CGFloat, font: NSFont) -> CGFloat {
        baseline + firstBaselineInset(for: font)
    }

    static func baseline(forTopEdge top: CGFloat, font: NSFont) -> CGFloat {
        top - firstBaselineInset(for: font)
    }

    static func baseline(of annotation: PDFAnnotation) -> CGFloat? {
        guard let font = annotation.font else { return nil }
        return baseline(forTopEdge: annotation.bounds.maxY, font: font)
    }

    static func lineHeight(for font: NSFont) -> CGFloat {
        max(1, NSLayoutManager().defaultLineHeight(for: font))
    }

    /// The annotation rectangle that covers `cover` and puts the first line on `firstBaseline`.
    static func textBounds(covering cover: CGRect, firstBaseline: CGFloat, font: NSFont) -> CGRect {
        let top = topEdge(forBaseline: firstBaseline, font: font)
        return CGRect(
            x: cover.minX - horizontalInset,
            y: cover.minY,
            width: cover.width + horizontalInset * 2,
            height: max(4, top - cover.minY)
        )
    }

    /// Antialiased glyph edges reach a little past the reported text bounds, so the
    /// opaque rectangle is grown by a hair before it is put on the page.
    static let coverPadding: CGFloat = 1

    /// The opaque rectangle that hides the replaced page text, inverse of `textBounds(covering:…)`.
    static func coverBounds(for textBounds: CGRect, font: NSFont) -> CGRect {
        let overhang = max(0, firstBaselineInset(for: font) - font.ascender)
        return CGRect(
            x: textBounds.minX + horizontalInset,
            y: textBounds.minY,
            width: max(1, textBounds.width - horizontalInset * 2),
            height: max(1, textBounds.height - overhang)
        )
    }

    static func availableTextWidth(in bounds: CGRect) -> CGFloat {
        max(1, bounds.width - horizontalInset * 2)
    }

    static func availableTextHeight(in bounds: CGRect) -> CGFloat {
        max(1, bounds.height - topPadding)
    }
}

/// One line of the page, with the baseline its replacement has to sit on.
struct ReplaceableLine {
    let text: String
    let bounds: CGRect
    let baseline: CGFloat
}

/// A run of existing page text that the Edit Text tool can replace in place.
struct ReplaceableText {
    let page: PDFPage
    let text: String
    let font: NSFont
    let fontColor: NSColor
    let backgroundColor: NSColor
    let coverBounds: CGRect
    let firstBaseline: CGFloat
    let lines: [ReplaceableLine]

    var isMultiline: Bool { lines.count > 1 }

    var textBounds: CGRect {
        FreeTextLayout.textBounds(covering: coverBounds, firstBaseline: firstBaseline, font: font)
    }

    /// The box a replacement for `line` occupies, keeping the document's own line spacing
    /// instead of reflowing the block with the font's.
    func textBounds(for line: ReplaceableLine) -> CGRect {
        FreeTextLayout.textBounds(covering: line.bounds, firstBaseline: line.baseline, font: font)
    }
}

/// Lays a replacement out over the lines it replaces, filling each to its own width.
enum LineDistributor {
    static func distribute(_ text: String, across widths: [CGFloat], font: NSFont) -> [String] {
        guard widths.count > 1 else { return [text] }
        var words = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        var lines: [String] = []
        for (index, width) in widths.enumerated() {
            let isLast = index == widths.count - 1
            if isLast {
                lines.append(words.joined(separator: " "))
                words = []
                continue
            }
            var line = ""
            while let word = words.first {
                let candidate = line.isEmpty ? word : line + " " + word
                let measured = NSAttributedString(string: candidate, attributes: [.font: font]).size().width
                if !line.isEmpty, measured > FreeTextLayout.availableTextWidth(in: CGRect(x: 0, y: 0, width: width, height: 1)) {
                    break
                }
                line = candidate
                words.removeFirst()
            }
            lines.append(line)
        }
        return lines
    }
}

enum PageTextScanner {
    static func replaceableText(at point: CGPoint, on page: PDFPage) -> ReplaceableText? {
        guard let selection = lineSelection(at: point, on: page) else { return nil }
        return replaceableText(lines: [selection], on: page)
    }

    /// The outline of the line under the pointer, without the cost of reading the paper
    /// color back, so the hover highlight stays cheap.
    static func lineBounds(at point: CGPoint, on page: PDFPage) -> CGRect? {
        guard let selection = lineSelection(at: point, on: page) else { return nil }
        let bounds = selection.bounds(for: page)
        return bounds.width > 0 && bounds.height > 0 ? bounds : nil
    }

    /// PDFKit only reports a line when the point lands inside a glyph, so a click on the
    /// first letter, in the gap between words, or just off the end of a line finds nothing.
    /// Probing a small rectangle around the point picks the intended line instead.
    private static func lineSelection(at point: CGPoint, on page: PDFPage) -> PDFSelection? {
        if let direct = page.selectionForLine(at: point), let text = direct.string, !text.isEmpty {
            return direct
        }
        let probe = CGRect(x: point.x - 10, y: point.y - 6, width: 20, height: 12)
        guard let selection = page.selection(for: probe) else { return nil }
        let candidates = selection.selectionsByLine().filter { !($0.string ?? "").isEmpty }
        let best = candidates.min { first, second in
            verticalDistance(from: point.y, to: first.bounds(for: page))
                < verticalDistance(from: point.y, to: second.bounds(for: page))
        }
        guard let best else { return nil }
        return expanded(best, on: page)
    }

    private static func verticalDistance(from y: CGFloat, to bounds: CGRect) -> CGFloat {
        if bounds.minY <= y, y <= bounds.maxY { return 0 }
        return min(abs(y - bounds.minY), abs(y - bounds.maxY))
    }

    static func replaceableText(in rect: CGRect, on page: PDFPage) -> ReplaceableText? {
        guard rect.width > 1, rect.height > 1, let selection = page.selection(for: rect) else { return nil }
        let lines = selection.selectionsByLine()
            .map { expanded($0, on: page) }
            .sorted { $0.bounds(for: page).maxY > $1.bounds(for: page).maxY }
        guard !lines.isEmpty else { return nil }
        return replaceableText(lines: lines, on: page)
    }

    /// Widens a partially selected line to the whole visual line, the way a text editor
    /// would operate on complete lines rather than on glyph fragments.
    private static func expanded(_ line: PDFSelection, on page: PDFPage) -> PDFSelection {
        let bounds = line.bounds(for: page)
        guard bounds.width > 0, bounds.height > 0,
              let full = page.selectionForLine(at: CGPoint(x: bounds.midX, y: bounds.midY)),
              let text = full.string, !text.isEmpty else { return line }
        return full
    }

    private static func replaceableText(lines: [PDFSelection], on page: PDFPage) -> ReplaceableText? {
        var strings: [String] = []
        var union: CGRect = .null
        for line in lines {
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { continue }
            strings.append(line.string ?? "")
            union = union.union(bounds)
        }
        guard !union.isNull, !strings.isEmpty else { return nil }
        let text = strings.joined(separator: "\n").trimmingCharacters(in: .newlines)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        guard let first = lines.first else { return nil }
        let firstBounds = first.bounds(for: page)
        let style = textStyle(of: first, fallbackHeight: firstBounds.height)
        let backgroundColor = PageBackgroundSampler.dominantColor(in: union, on: page)
        let replaceableLines = zip(lines, strings).compactMap { line, string -> ReplaceableLine? in
            let bounds = line.bounds(for: page)
            guard bounds.width > 0, bounds.height > 0 else { return nil }
            return ReplaceableLine(
                text: string,
                bounds: bounds,
                baseline: bounds.minY - style.font.descender
            )
        }
        return ReplaceableText(
            page: page,
            text: text,
            font: style.font,
            fontColor: style.color,
            backgroundColor: backgroundColor,
            coverBounds: union,
            firstBaseline: firstBounds.minY - style.font.descender,
            lines: replaceableLines
        )
    }

    private static func textStyle(of selection: PDFSelection, fallbackHeight: CGFloat) -> (font: NSFont, color: NSColor) {
        let fallbackFont = NSFont(name: "Helvetica", size: max(6, fallbackHeight)) ?? .systemFont(ofSize: max(6, fallbackHeight))
        guard let attributed = selection.attributedString, attributed.length > 0 else {
            return (fallbackFont, .black)
        }
        let attributes = attributed.attributes(at: 0, effectiveRange: nil)
        let font = (attributes[.font] as? NSFont) ?? fallbackFont
        let color = (attributes[.foregroundColor] as? NSColor) ?? .black
        return (font, color)
    }
}

/// Reads the page back as pixels to find the paper color behind a run of text, so the
/// replacement blends into tinted backgrounds instead of punching a white hole.
enum PageBackgroundSampler {
    static func dominantColor(in rect: CGRect, on page: PDFPage) -> NSColor {
        let visibility = page.annotations.map { ($0, $0.shouldDisplay) }
        for (annotation, _) in visibility { annotation.shouldDisplay = false }
        defer { for (annotation, wasVisible) in visibility { annotation.shouldDisplay = wasVisible } }

        let box = PDFDisplayBox.mediaBox
        let sample = rect.insetBy(dx: -2, dy: -2)
        let device = sample.applying(page.transform(for: box))
        let scale: CGFloat = 2
        let width = Int((device.width * scale).rounded())
        let height = Int((device.height * scale).rounded())
        guard width > 0, height > 0, width * height <= 4_000_000,
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return .white }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -device.minX, y: -device.minY)
        page.draw(with: box, to: context)

        guard let image = context.makeImage() else { return .white }
        let bitmap = NSBitmapImageRep(cgImage: image)
        var histogram: [UInt32: Int] = [:]
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                histogram[quantized(color), default: 0] += 1
            }
        }
        guard let dominant = histogram.max(by: { $0.value < $1.value })?.key else { return .white }
        return color(from: dominant)
    }

    private static func quantized(_ color: NSColor) -> UInt32 {
        let red = UInt32((color.redComponent * 63).rounded())
        let green = UInt32((color.greenComponent * 63).rounded())
        let blue = UInt32((color.blueComponent * 63).rounded())
        return (red << 16) | (green << 8) | blue
    }

    private static func color(from quantized: UInt32) -> NSColor {
        NSColor(
            deviceRed: CGFloat((quantized >> 16) & 63) / 63,
            green: CGFloat((quantized >> 8) & 63) / 63,
            blue: CGFloat(quantized & 63) / 63,
            alpha: 1
        )
    }
}

enum TextFitting {
    /// Replacements shrink a little to stay on their line, but never so much that the
    /// page visibly changes typeface size; past that point the text wraps instead.
    static let minimumScale: CGFloat = 0.7
    static let minimumSize: CGFloat = 4

    struct Result {
        let font: NSFont
        let bounds: CGRect
    }

    /// Keeps a replacement inside the page: a longer line first widens into the margin,
    /// then shrinks, and only wraps onto extra lines when nothing else is left.
    static func fit(
        text: String,
        font: NSFont,
        in bounds: CGRect,
        multiline: Bool,
        within limit: CGRect
    ) -> Result {
        guard !text.isEmpty else { return Result(font: font, bounds: bounds) }
        let wraps = multiline || text.contains("\n")
        var box = bounds

        if !wraps {
            let needed = ceil(measure(text, font: font).width) + FreeTextLayout.horizontalInset * 2 + 1
            if needed > box.width, limit.width > 0 {
                let margin = max(12, box.minX - limit.minX)
                let maximumWidth = max(box.width, limit.maxX - margin - box.minX)
                box.size.width = min(needed, maximumWidth)
            }
        }

        var fitted = font
        if !fits(text, font: fitted, in: box, multiline: wraps) {
            let floorSize = max(minimumSize, font.pointSize * minimumScale)
            var size = font.pointSize
            while size > floorSize {
                size = max(floorSize, size - 0.5)
                fitted = resized(font, to: size)
                if fits(text, font: fitted, in: box, multiline: wraps) { break }
            }
        }

        if !fits(text, font: fitted, in: box, multiline: wraps) {
            let needed = wrappedHeight(text, font: fitted, width: FreeTextLayout.availableTextWidth(in: box))
                + FreeTextLayout.topPadding
            if needed > box.height {
                let extra = needed - box.height
                box.origin.y -= extra
                box.size.height += extra
            }
        }
        return Result(font: fitted, bounds: box)
    }

    static func fittedFont(for text: String, font: NSFont, in bounds: CGRect, multiline: Bool) -> NSFont {
        fit(text: text, font: font, in: bounds, multiline: multiline, within: bounds).font
    }

    static func fits(_ text: String, font: NSFont, in bounds: CGRect, multiline: Bool) -> Bool {
        fits(
            text,
            font: font,
            width: FreeTextLayout.availableTextWidth(in: bounds),
            height: FreeTextLayout.availableTextHeight(in: bounds),
            multiline: multiline
        )
    }

    static func fits(_ text: String, font: NSFont, width: CGFloat, height: CGFloat, multiline: Bool) -> Bool {
        guard multiline || text.contains("\n") else {
            return ceil(measure(text, font: font).width) <= ceil(width)
        }
        return ceil(wrappedHeight(text, font: font, width: width)) <= ceil(height)
    }

    static func resized(_ font: NSFont, to size: CGFloat) -> NSFont {
        if font.fontName.hasPrefix(".") { return .systemFont(ofSize: size) }
        return NSFont(name: font.fontName, size: size)
            ?? NSFontManager.shared.convert(font, toSize: size)
    }

    private static func measure(_ text: String, font: NSFont) -> CGSize {
        NSAttributedString(string: text, attributes: [.font: font]).size()
    }

    private static func wrappedHeight(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: max(1, width), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
    }
}

/// Marks the two annotations that make up one replaced run of text, so the pair survives
/// saving and can still be moved, resized, and deleted as a single object after reopening.
enum TextEditMarker {
    private static let prefix = "zzPDF Text Edit"

    static func makeIdentifier() -> String {
        "\(prefix) \(UUID().uuidString)"
    }

    static func isTextEdit(_ annotation: PDFAnnotation) -> Bool {
        annotation.userName?.hasPrefix(prefix) == true
    }
}
