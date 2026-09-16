import AppKit
import PDFKit

@main
@MainActor
struct PageStampSmoke {
    static let body = "Il corpo del documento resta leggibile."

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-stamp-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.stamp.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(pages: 4, in: directory))
        view.document = workspace.pdfDocument
        guard let document = workspace.pdfDocument else { fail("The fixture did not open") }

        // Tokens expand to the page, the total, the file, and a Bates number.
        var options = PageStamper.Options()
        options.text = "{file} — page {page} of {pages} — {bates}"
        options.batesPrefix = "ACME"
        options.batesStart = 41
        options.batesDigits = 5
        let expanded = PageStamper.expand(
            options.text,
            pageIndex: 2,
            pageCount: 4,
            documentName: "Contratto",
            sequence: 2,
            options: options
        )
        check(
            expanded == "Contratto — page 3 of 4 — ACME00043",
            "The tokens expanded to \"\(expanded)\""
        )

        // Stamping rebuilds the pages and keeps the document's own text searchable.
        workspace.beginPageStamp(options)
        check(workspace.stampTargetIndexes == [0, 1, 2, 3], "The stamp targets \(workspace.stampTargetIndexes)")
        workspace.applyPageStamp()
        check(workspace.isDirty, "Stamping did not mark the document as edited")
        check(document.pageCount == 4, "Stamping left \(document.pageCount) pages")
        check(
            !document.findString(body, withOptions: []).isEmpty,
            "Stamping cost the document its own text"
        )
        check(
            !document.findString("ACME00041", withOptions: []).isEmpty,
            "The first Bates number is not on the page"
        )
        check(
            !document.findString("ACME00044", withOptions: []).isEmpty,
            "The Bates numbers did not run on across the pages"
        )
        check(
            !document.findString("page 2 of 4", withOptions: []).isEmpty,
            "The page numbering is not on the page"
        )
        check(
            document.page(at: 0)?.annotations.isEmpty == true,
            "The stamp was added as an annotation instead of page content"
        )

        // One undo step takes all four pages back.
        workspace.undo()
        check(
            document.findString("ACME00041", withOptions: []).isEmpty,
            "Undo left the stamp on the page"
        )
        check(
            !document.findString(body, withOptions: []).isEmpty,
            "Undo cost the document its own text"
        )
        workspace.redo()
        check(!document.findString("ACME00041", withOptions: []).isEmpty, "Redo did not put the stamp back")
        workspace.undo()

        // A rotated page keeps the size it is displayed at: the stamp is drawn the right
        // way up, so the rebuilt page carries the rotated extent and no rotation of its own.
        let uprightSize = document.page(at: 1)?.bounds(for: .cropBox).size ?? .zero
        document.page(at: 1)?.rotation = 90
        workspace.beginPageStamp(options)
        workspace.applyPageStamp()
        guard let stampedPage = document.page(at: 1) else { fail("The rotated page is gone") }
        let stampedSize = stampedPage.bounds(for: .cropBox).size
        check(
            abs(stampedSize.width - uprightSize.height) < 1 && abs(stampedSize.height - uprightSize.width) < 1,
            "A rotated \(uprightSize) page stamped to \(stampedSize) instead of its rotated extent"
        )
        check(stampedPage.rotation == 0, "The rebuilt page still claims a rotation of \(stampedPage.rotation)")
        check(
            stampedPage.string?.contains("ACME") == true,
            "The stamp did not land on the rotated page"
        )
        workspace.undo()

        // A watermark only touches the selected pages when asked to.
        workspace.selectPage(1)
        workspace.extendPageSelection(to: 2)
        workspace.beginPageStamp(.watermark)
        check(
            workspace.stampAppliesToSelectionOnly,
            "A multiple selection did not narrow the stamp to those pages"
        )
        check(workspace.stampTargetIndexes == [1, 2], "The stamp targets \(workspace.stampTargetIndexes)")
        workspace.applyPageStamp()
        check(
            document.page(at: 1)?.string?.contains("DRAFT") == true,
            "The watermark is not on the second page"
        )
        check(
            document.page(at: 0)?.string?.contains("DRAFT") != true,
            "The watermark reached a page outside the selection"
        )

        // A stamp with no text does nothing rather than rebuilding pages for nothing.
        check(
            PageStamper.stamped(document.page(at: 0)!, text: "   ", options: options) == nil,
            "An empty stamp still rebuilt the page"
        )

        // The preview renders the page it says it will.
        check(workspace.stampPreview(size: CGSize(width: 200, height: 260)) != nil, "The preview came back empty")

        print("Page stamping smoke test passed.")
    }

    private static func makePDF(pages: Int, in directory: URL) -> URL {
        let url = directory.appendingPathComponent("stamp.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 560)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for _ in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
            let attributed = NSAttributedString(string: body, attributes: [.font: font])
            context.textPosition = CGPoint(x: 50, y: 400)
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
        FileHandle.standardError.write(Data("Page stamping smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
