import AppKit
import PDFKit

@main
@MainActor
struct ReadingAndAutosaveSmoke {
    static let line = "Riga originale del documento"

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-reading-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.reading.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.temporaryAutosave = true

        let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: recoveryDirectory)
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 400),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
        window.contentView = view
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(in: directory))
        view.document = workspace.pdfDocument
        view.layoutDocumentView()
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }

        // Normal reading leaves no filter on the layer at all. An empty list is not the
        // same as none: it still rasterizes the page before it reaches the screen, which
        // softens every glyph on it.
        workspace.setReadingMode(.normal)
        view.refreshInteractionAppearance()
        check(
            view.layer?.filters == nil,
            "Normal reading left \((view.layer?.filters?.count ?? 0)) filters on the layer"
        )

        workspace.setReadingMode(.night)
        check((view.layer?.filters?.count ?? 0) == 1, "Night reading installed no filter")
        check(
            (view.layer?.contentsScale ?? 0) >= 1,
            "The tinted layer was left at a coarser scale than the screen"
        )
        workspace.setReadingMode(.sepia)
        check((view.layer?.filters?.count ?? 0) == 1, "Sepia reading installed no filter")
        workspace.setReadingMode(.normal)
        check(view.layer?.filters == nil, "Going back to normal left a filter behind")

        // The recovery autosave must not touch an edit in progress. It used to finish it,
        // so a line left open for a moment was committed under the reader's hands.
        workspace.activateTool(.editText)
        workspace.beginTextReplacement(at: CGPoint(x: 80, y: 124), on: page)
        guard let editing = workspace.selectedAnnotation else { fail("No edit was started") }
        workspace.previewTextEdit("STO ANCORA SCRIVENDO")
        let annotationsWhileEditing = page.annotations.count

        // Run the loop well past the 1.5 second autosave, several times over.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(view.activeInlineEditor != nil, "The autosave closed the editor")
        check(editing.contents == "STO ANCORA SCRIVENDO", "The autosave changed what was being typed")
        check(
            page.annotations.count == annotationsWhileEditing,
            "The autosave changed the page from \(annotationsWhileEditing) to \(page.annotations.count) annotations"
        )
        check(
            workspace.statusMessage.contains("Editing page text"),
            "The autosave ended the edit: \"\(workspace.statusMessage)\""
        )

        // Once the edit is committed, the copy is written as usual.
        workspace.commitTextReplacement(editing, text: "TESTO SOSTITUITO")
        let writeDeadline = Date().addingTimeInterval(5)
        while Date() < writeDeadline,
              TemporaryRecoveryStore(directoryURL: recoveryDirectory).pendingRecords().isEmpty {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        check(
            !TemporaryRecoveryStore(directoryURL: recoveryDirectory).pendingRecords().isEmpty,
            "No recovery copy was written once the edit was over"
        )

        print("Reading mode and autosave smoke test passed.")
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("reading.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 17, nil)
        let attributed = NSAttributedString(string: line, attributes: [.font: font])
        context.textPosition = CGPoint(x: 40, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Reading mode and autosave smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
