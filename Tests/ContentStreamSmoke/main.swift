import AppKit
import PDFKit

/// Taking text back out of a page's content stream.
///
/// This is the one piece of the app that edits PDF bytes rather than going through PDFKit,
/// so what it must never do matters as much as what it must: the rest of the page has to
/// come through untouched, and a file it cannot safely edit has to be left alone.
@main
struct ContentStreamSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-stream-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let generated = rebuild(makePDF(in: directory))
        // Which object number it lands on is Core Graphics' business and differs between
        // releases; that it is found at all is this app's.
        guard let contents = ContentStreamEditor.contentsObject(in: generated) else {
            fail("The content stream was not found")
        }
        check(contents > 0, "The content stream is object \(contents)")
        guard let stream = ContentStreamEditor.decodedContentStream(of: generated) else {
            fail("The content stream could not be decoded")
        }
        let text = String(decoding: stream, as: UTF8.self)
        check(text.contains("TJ") || text.contains("Tj"), "The stream draws no text: \(text.prefix(120))")

        // The run inside the rectangle goes; everything else stays exactly as it was.
        let hole = CGRect(x: 20, y: 140, width: 220, height: 26)
        guard let updated = ContentStreamEditor.removingText(inside: [hole], from: generated) else {
            fail("Nothing was removed")
        }
        guard let page = PDFDocument(data: updated)?.page(at: 0) else {
            fail("The edited file could not be reopened")
        }
        let remaining = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        check(remaining == "SECONDA RIGA", "The page reads \"\(remaining)\" instead of just the second line")
        check(
            PDFDocument(data: updated)!.findString("PRIMA RIGA", withOptions: []).isEmpty,
            "Find still turns up the removed line"
        )

        // The page keeps its size, and the file keeps everything else in it: an edit that
        // silently dropped a font or a colour profile would show as a blank page.
        check(page.bounds(for: .cropBox).size == CGSize(width: 300, height: 200), "The page changed size")
        check(updated.count > generated.count / 2, "The file lost most of itself: \(updated.count) bytes")

        // A rectangle with nothing in it changes nothing, and says so, so the caller keeps
        // the file it already had rather than a needlessly rewritten one.
        check(
            ContentStreamEditor.removingText(inside: [CGRect(x: 250, y: 10, width: 40, height: 20)], from: generated) == nil,
            "An empty rectangle rewrote the file anyway"
        )
        check(
            ContentStreamEditor.removingText(inside: [], from: generated) == nil,
            "No rectangles at all rewrote the file anyway"
        )

        // Something that is not a PDF this app just wrote is left alone rather than damaged.
        check(
            ContentStreamEditor.removingText(inside: [hole], from: Data("not a pdf".utf8)) == nil,
            "A file that is not a PDF was edited"
        )

        streamEditing()
        print("Content stream smoke test passed.")
    }

    /// The tokeniser, on the shapes a real stream contains.
    private static func streamEditing() {
        // Only the run whose origin falls inside the rectangle is emptied, and the operators
        // that move the pen are left alone so everything after it still lands where it did.
        let stream = Data("""
        BT 1 0 0 1 30 150 Tm (rimuovimi) Tj 0 -20 Td (tienimi) Tj ET
        """.utf8)
        let edited = ContentStreamEditor.removingText(
            inside: [CGRect(x: 20, y: 140, width: 100, height: 20)],
            fromStream: stream
        )
        let result = String(decoding: edited, as: UTF8.self)
        check(!result.contains("rimuovimi"), "The run inside the rectangle survived: \(result)")
        check(result.contains("(tienimi) Tj"), "The run outside the rectangle was touched: \(result)")
        check(result.contains("0 -20 Td"), "A positioning operator was lost: \(result)")
        check(result.contains("() Tj"), "The emptied run lost its operator: \(result)")

        // A string holding brackets and escapes is one string, not the start of trouble.
        let awkward = Data("BT 1 0 0 1 30 150 Tm (a \\(b\\) c) Tj ET (fuori) Tj".utf8)
        let untouched = ContentStreamEditor.removingText(
            inside: [CGRect(x: 0, y: 0, width: 10, height: 10)],
            fromStream: awkward
        )
        check(untouched == awkward, "A stream with nothing to remove came back changed")

        // Text drawn under a transform is placed by that transform, not by its own numbers.
        let shifted = Data("q 1 0 0 1 100 0 cm BT 1 0 0 1 30 150 Tm (spostato) Tj ET Q".utf8)
        let missed = ContentStreamEditor.removingText(
            inside: [CGRect(x: 20, y: 140, width: 40, height: 20)],
            fromStream: shifted
        )
        check(missed == shifted, "A run was removed from where it is written rather than where it is drawn")
        let hit = ContentStreamEditor.removingText(
            inside: [CGRect(x: 120, y: 140, width: 40, height: 20)],
            fromStream: shifted
        )
        check(
            !String(decoding: hit, as: UTF8.self).contains("spostato"),
            "A run under a transform was not found where it is drawn"
        )
    }

    /// A page redrawn into a new PDF, the way a text replacement rebuilds one.
    private static func rebuild(_ url: URL) -> Data {
        guard let page = PDFDocument(url: url)?.page(at: 0) else { fail("The fixture has no page") }
        var mediaBox = CGRect(origin: .zero, size: page.bounds(for: .cropBox).size)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data as CFMutableData)!
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
        context.beginPDFPage(nil)
        page.draw(with: .cropBox, to: context)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("due-righe.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        for (text, y) in [("PRIMA RIGA", 150), ("SECONDA RIGA", 100)] {
            let line = NSAttributedString(string: text, attributes: [.font: font])
            context.textPosition = CGPoint(x: 30, y: CGFloat(y))
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Content stream smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
