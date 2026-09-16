import AppKit
import PDFKit

/// Draws page numbers, headers, footers, Bates numbers, and watermarks into the page
/// itself rather than on top of it as an annotation.
///
/// A page redrawn into a PDF context keeps its vectors and its text: nothing is rasterized
/// and the document stays searchable, which is what lets a stamp be permanent without
/// costing the page its quality.
enum PageStamper {
    enum Placement: String, CaseIterable, Identifiable {
        case topLeft, topCenter, topRight
        case center
        case bottomLeft, bottomCenter, bottomRight

        var id: String { rawValue }

        var label: String {
            switch self {
            case .topLeft: "Top left"
            case .topCenter: "Top centre"
            case .topRight: "Top right"
            case .center: "Centre"
            case .bottomLeft: "Bottom left"
            case .bottomCenter: "Bottom centre"
            case .bottomRight: "Bottom right"
            }
        }

        var isTop: Bool { self == .topLeft || self == .topCenter || self == .topRight }
        var isBottom: Bool { self == .bottomLeft || self == .bottomCenter || self == .bottomRight }

        var horizontal: NSTextAlignment {
            switch self {
            case .topLeft, .bottomLeft: .left
            case .topRight, .bottomRight: .right
            case .topCenter, .bottomCenter, .center: .center
            }
        }
    }

    struct Options {
        var text = "Page {page} of {pages}"
        var placement: Placement = .bottomCenter
        var fontName = "Helvetica"
        var fontSize: CGFloat = 10
        var color: NSColor = .black
        var opacity: Double = 1
        var rotation: Double = 0
        var margin: CGFloat = 36
        var batesPrefix = ""
        var batesStart = 1
        var batesDigits = 6

        static var watermark: Options {
            Options(
                text: "DRAFT",
                placement: .center,
                fontName: "Helvetica-Bold",
                fontSize: 72,
                color: .systemRed,
                opacity: 0.18,
                rotation: 38,
                margin: 0
            )
        }
    }

    /// The placeholders a stamp can contain, shown to the user next to the text field.
    static let tokenHelp = "{page} {pages} {file} {date} {bates}"

    static func expand(
        _ text: String,
        pageIndex: Int,
        pageCount: Int,
        documentName: String,
        sequence: Int,
        options: Options
    ) -> String {
        let bates = options.batesPrefix
            + String(format: "%0\(max(1, min(options.batesDigits, 12)))d", options.batesStart + sequence)
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return text
            .replacingOccurrences(of: "{page}", with: "\(pageIndex + 1)")
            .replacingOccurrences(of: "{pages}", with: "\(pageCount)")
            .replacingOccurrences(of: "{file}", with: documentName)
            .replacingOccurrences(of: "{date}", with: formatter.string(from: Date()))
            .replacingOccurrences(of: "{bates}", with: bates)
    }

    /// A copy of `page` with `text` drawn onto it.
    static func stamped(_ page: PDFPage, text: String, options: Options) -> PDFPage? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let box = PDFDisplayBox.cropBox
        var mediaBox = page.bounds(for: box)
        guard mediaBox.width > 1, mediaBox.height > 1 else { return nil }
        // A rotated page draws with its sides swapped, so the new page takes the rotated extent.
        if abs(page.rotation % 180) == 90 {
            mediaBox = CGRect(x: 0, y: 0, width: mediaBox.height, height: mediaBox.width)
        } else {
            mediaBox = CGRect(origin: .zero, size: mediaBox.size)
        }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        page.draw(with: box, to: context)
        draw(trimmed, in: context, pageRect: mediaBox, options: options)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data), let stamped = document.page(at: 0) else { return nil }
        return stamped
    }

    private static func draw(_ text: String, in context: CGContext, pageRect: CGRect, options: Options) {
        let font = CTFontCreateWithName(
            (options.fontName as CFString),
            max(1, options.fontSize),
            nil
        )
        let color = options.color.withAlphaComponent(CGFloat(max(0, min(options.opacity, 1))))
        let lines = text.components(separatedBy: "\n")
        let lineHeight = CTFontGetAscent(font) + CTFontGetDescent(font) + CTFontGetLeading(font)

        context.saveGState()
        defer { context.restoreGState() }

        if options.rotation != 0 {
            context.translateBy(x: pageRect.midX, y: pageRect.midY)
            context.rotate(by: CGFloat(options.rotation) * .pi / 180)
            context.translateBy(x: -pageRect.midX, y: -pageRect.midY)
        }

        let blockHeight = lineHeight * CGFloat(lines.count)
        for (index, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: font, .foregroundColor: color]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))

            let x: CGFloat
            switch options.placement.horizontal {
            case .right: x = pageRect.maxX - options.margin - width
            case .center: x = pageRect.midX - width / 2
            default: x = pageRect.minX + options.margin
            }

            let firstBaseline: CGFloat
            if options.placement.isTop {
                firstBaseline = pageRect.maxY - options.margin - CTFontGetAscent(font)
            } else if options.placement.isBottom {
                firstBaseline = pageRect.minY + options.margin + CTFontGetDescent(font) + blockHeight - lineHeight
            } else {
                firstBaseline = pageRect.midY + blockHeight / 2 - CTFontGetAscent(font)
            }

            context.textPosition = CGPoint(x: x, y: firstBaseline - lineHeight * CGFloat(index))
            CTLineDraw(ctLine, context)
        }
    }
}
