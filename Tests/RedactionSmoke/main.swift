import AppKit
import PDFKit

@main
@MainActor
struct RedactionSmoke {
    static let secret = "SEGRETO 12345"
    static let keep = "Questa riga resta leggibile"

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-redaction-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = makeSourcePDF(in: directory)
        guard let document = PDFDocument(url: source),
              let first = document.page(at: 0),
              let second = document.page(at: 1) else {
            fail("The prepared document could not be opened")
        }

        let redaction = PDFAnnotation(
            bounds: CGRect(x: 25, y: 115, width: 180, height: 24),
            forType: .square,
            withProperties: nil
        )
        redaction.color = .black
        redaction.interiorColor = .black
        redaction.contents = RedactionFlattener.marker
        let border = PDFBorder()
        border.lineWidth = 0
        redaction.border = border
        first.addAnnotation(redaction)

        check(
            RedactionFlattener.redactedPageIndexes(in: document) == [0],
            "The redacted page was not recognized"
        )
        check(
            RedactionFlattener.exportWarning(redactedPageCount: 1).contains("1 page"),
            "The export warning does not mention the rasterized page"
        )
        check(
            !RedactionFlattener.exportWarning(redactedPageCount: 0).contains("image"),
            "The export warning mentions rasterizing even without a redaction"
        )

        // Burning the annotation in is not enough on its own: the words stay in the file.
        let burnedIn = directory.appendingPathComponent("burned-in.pdf")
        check(
            document.write(to: burnedIn, withOptions: [.burnInAnnotationsOption: true]),
            "The burn-in comparison file could not be written"
        )
        if let reopened = PDFDocument(url: burnedIn) {
            check(
                !reopened.findString(secret, withOptions: .caseInsensitive).isEmpty,
                "This test no longer proves anything: PDFKit now drops burned-over text by itself"
            )
        }

        // The export the app actually performs has to remove them.
        guard let flattened = RedactionFlattener.rasterizingRedactedPages(of: document) else {
            fail("Flattening a redacted document returned nothing to export")
        }
        let exported = directory.appendingPathComponent("flattened.pdf")
        check(
            flattened.write(to: exported, withOptions: [.burnInAnnotationsOption: true]),
            "The flattened copy could not be written"
        )
        guard let result = PDFDocument(url: exported) else { fail("The flattened copy could not be reopened") }
        check(result.pageCount == 2, "The flattened copy has \(result.pageCount) pages instead of 2")
        check(
            result.findString(secret, withOptions: .caseInsensitive).isEmpty,
            "The redacted text is still searchable in the exported copy"
        )
        check(
            (result.page(at: 0)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The redacted page still exposes extractable text"
        )
        check(
            result.page(at: 0)?.annotations.isEmpty == true,
            "The rasterized page still carries annotations"
        )

        // Untouched pages keep their text: only redacted pages become images.
        check(
            !result.findString(keep, withOptions: .caseInsensitive).isEmpty,
            "A page without redactions lost its text"
        )

        // Page geometry survives rasterizing, including a rotated page.
        let originalBounds = first.bounds(for: .cropBox)
        let exportedBounds = result.page(at: 0)?.bounds(for: .cropBox) ?? .zero
        check(
            abs(exportedBounds.width - originalBounds.width) < 1
                && abs(exportedBounds.height - originalBounds.height) < 1,
            "The rasterized page measures \(exportedBounds.size) instead of \(originalBounds.size)"
        )

        second.rotation = 90
        let rotated = PDFAnnotation(
            bounds: CGRect(x: 25, y: 115, width: 180, height: 24),
            forType: .square,
            withProperties: nil
        )
        rotated.color = .black
        rotated.interiorColor = .black
        rotated.contents = RedactionFlattener.marker
        rotated.border = border
        second.addAnnotation(rotated)
        guard let bothFlattened = RedactionFlattener.rasterizingRedactedPages(of: document),
              let rotatedPage = bothFlattened.page(at: 1) else {
            fail("Flattening a rotated redacted page returned nothing")
        }
        let rotatedBounds = rotatedPage.bounds(for: .cropBox)
        let expected = second.bounds(for: .cropBox)
        check(
            abs(rotatedBounds.width - expected.height) < 1 && abs(rotatedBounds.height - expected.width) < 1,
            "A rotated page rasterized to \(rotatedBounds.size) instead of the rotated \(expected.size)"
        )

        // A document with no redaction is left alone so its text stays intact.
        guard let plain = PDFDocument(url: source) else { fail("The plain document could not be reopened") }
        check(
            RedactionFlattener.rasterizingRedactedPages(of: plain) == nil,
            "A document without redactions was rasterized anyway"
        )

        print("Redaction flattening smoke test passed.")
    }

    private static func makeSourcePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("source.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for text in [secret, keep] {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: font, .foregroundColor: NSColor.black]
            )
            context.textPosition = CGPoint(x: 30, y: 120)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Redaction flattening smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
