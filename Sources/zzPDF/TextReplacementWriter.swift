import AppKit
import PDFKit

/// Writes a finished text replacement into the page itself.
///
/// While a line is being edited it is an annotation, which is what makes the edit live,
/// undoable, and cheap. Leaving it as one afterwards is what made a replaced line look
/// unlike the rest of the page: PDFKit draws annotations through its own path, at its own
/// quality, rather than as page content. Redrawing the page into a PDF context keeps every
/// vector and every glyph of the original, so the replacement ends up made of the same
/// stuff as the text around it — and renders, prints, and exports identically.
enum TextReplacementWriter {
    struct Line {
        /// The rectangle hiding the original run, in page coordinates.
        let cover: CGRect
        let baseline: CGFloat
        let text: String
        let font: NSFont
        let color: NSColor
    }

    /// A copy of `page` with each line's original run painted over and the new text in its
    /// place. Returns nil if there is nothing to draw or the page cannot be rebuilt.
    ///
    /// The page keeps its own rotation rather than having it baked in, and its annotations
    /// are left out of the drawing: they are the reader's notes, not page content, and are
    /// carried over to the new page by the caller. Without both, a replacement would flatten
    /// every note on the page and turn a rotated page into an upright one.
    static func page(
        replacing lines: [Line],
        background: NSColor,
        on page: PDFPage
    ) -> PDFPage? {
        try? rewrite(replacing: lines, background: background, on: page)
    }

    /// Why a page could not be rebuilt. Saying which step gave up is the difference between
    /// a fixable report and "it did not work".
    enum Failure: Error, CustomStringConvertible {
        case noLines
        case degeneratePage(CGSize)
        case noContext
        case unreadable(bytes: Int)
        case noPage(bytes: Int)

        var description: String {
            switch self {
            case .noLines: return "no lines to write"
            case .degeneratePage(let size): return "the page measures \(size)"
            case .noContext: return "a PDF context could not be created"
            case .unreadable(let bytes): return "the \(bytes)-byte rewrite could not be reopened"
            case .noPage(let bytes): return "the \(bytes)-byte rewrite came back with no page"
            }
        }
    }

    static func rewrite(
        replacing lines: [Line],
        background: NSColor,
        on page: PDFPage
    ) throws -> PDFPage {
        guard !lines.isEmpty else { throw Failure.noLines }
        let box = PDFDisplayBox.cropBox
        let bounds = page.bounds(for: box)
        guard bounds.width > 1, bounds.height > 1 else { throw Failure.degeneratePage(bounds.size) }

        var mediaBox = CGRect(origin: .zero, size: bounds.size)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw Failure.noContext
        }

        context.beginPDFPage(nil)

        // PDFPage.draw applies the page's rotation; undoing it first leaves the content in
        // the page's own coordinates, where the replacement and the annotations already live.
        context.saveGState()
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.concatenate(page.transform(for: box).inverted())
        let visibility = page.annotations.map { ($0, $0.shouldDisplay) }
        for (annotation, _) in visibility { annotation.shouldDisplay = false }
        page.draw(with: box, to: context)
        for (annotation, wasVisible) in visibility { annotation.shouldDisplay = wasVisible }
        context.restoreGState()

        context.saveGState()
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        context.setFillColor(background.cgColor)
        for line in lines { context.fill(line.cover) }
        for line in lines { draw(line, in: context) }
        context.restoreGState()

        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            throw Failure.unreadable(bytes: data.length)
        }
        guard let rewritten = document.page(at: 0) else {
            throw Failure.noPage(bytes: data.length)
        }
        rewritten.rotation = page.rotation
        return rewritten
    }

    /// Moves the reader's annotations from the page that was rewritten onto its replacement.
    static func transferAnnotations(from page: PDFPage, to rewritten: PDFPage) {
        let origin = page.bounds(for: .cropBox).origin
        for annotation in page.annotations {
            page.removeAnnotation(annotation)
            if origin != .zero {
                annotation.bounds = annotation.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
            }
            rewritten.addAnnotation(annotation)
        }
    }

    private static func draw(_ line: Line, in context: CGContext) {
        let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // From the descriptor, never from the name: a name that is not installed on this
        // Mac — which is what a PDF's embedded subset fonts are called — resolves silently
        // to Helvetica, and the replaced line comes out in a different typeface from the
        // text around it.
        let font = CTFontCreateWithFontDescriptor(
            line.font.fontDescriptor as CTFontDescriptor,
            line.font.pointSize,
            nil
        )
        let attributed = NSAttributedString(
            string: line.text,
            attributes: [.font: font, .foregroundColor: line.color]
        )
        let ctLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: line.cover.minX, y: line.baseline)
        CTLineDraw(ctLine, context)
    }
}
