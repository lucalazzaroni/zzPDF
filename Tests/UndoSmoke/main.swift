import AppKit
import PDFKit

/// A stand-in for whatever else registers undo in a document window: PDFKit's markup mode
/// and every text view in it put operations in the window's undo manager, and the
/// document's own undo used to replay them once its history ran out.
@MainActor
final class ForeignUndoTarget: NSObject {
    var replayCount = 0

    @objc func replay(_ sender: Any?) {
        replayCount += 1
    }
}

@main
@MainActor
struct UndoSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-undo-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.undo.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.confirmPageDeletion = false

        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 800),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 700, height: 800))
        window.contentView = view
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(pages: 3, in: directory))
        view.document = workspace.pdfDocument
        view.layoutDocumentView()

        guard let document = workspace.pdfDocument, let page = document.page(at: 0) else {
            fail("The fixture has no page")
        }
        check(!workspace.canUndo, "A freshly opened document already offers something to undo")
        check(!workspace.canRedo, "A freshly opened document already offers something to redo")

        // Something else in the window has undo history of its own.
        let foreign = ForeignUndoTarget()
        guard let windowUndo = view.undoManager else { fail("The window has no undo manager") }
        for _ in 0..<5 {
            windowUndo.registerUndo(withTarget: foreign, selector: #selector(ForeignUndoTarget.replay(_:)), object: nil)
        }
        check(windowUndo.canUndo, "The window's undo manager did not take the foreign operations")

        // Three edits of our own.
        workspace.activeTool = .rectangle
        for index in 0..<3 {
            let origin = CGPoint(x: 40 + Double(index) * 20, y: 40)
            workspace.addAnnotation(
                at: origin,
                on: page,
                dragPoints: [origin, CGPoint(x: origin.x + 70, y: origin.y + 60)]
            )
        }
        workspace.selectPage(1)
        workspace.deleteSelectedPages()
        check(page.annotations.count == 3, "The fixture holds \(page.annotations.count) annotations instead of 3")
        check(workspace.pageCount == 2, "Deleting a page left \(workspace.pageCount) pages")

        // Undo far past the end of our history.
        for _ in 0..<30 { workspace.undo() }
        check(workspace.pdfDocument === document, "Undoing too many times closed the document")
        check(workspace.pageCount == 3, "Undoing everything left \(workspace.pageCount) pages instead of 3")
        check(page.annotations.isEmpty, "Undoing everything left \(page.annotations.count) annotations")
        check(!workspace.isDirty, "Undoing everything left the document marked as edited")
        check(!workspace.canUndo, "There is still something to undo after undoing everything")
        check(workspace.canRedo, "Undoing everything left nothing to redo")
        check(
            foreign.replayCount == 0,
            "Undo replayed \(foreign.replayCount) operations belonging to the rest of the window"
        )
        check(windowUndo.canUndo, "Undo consumed the window's own undo history")

        // Redo far past the end, and back again, has to be just as stable.
        for _ in 0..<30 { workspace.redo() }
        check(workspace.pdfDocument === document, "Redoing too many times closed the document")
        check(workspace.pageCount == 2, "Redoing everything left \(workspace.pageCount) pages instead of 2")
        check(page.annotations.count == 3, "Redoing everything left \(page.annotations.count) annotations")
        check(!workspace.canRedo, "There is still something to redo after redoing everything")
        check(
            foreign.replayCount == 0,
            "Redo replayed \(foreign.replayCount) operations belonging to the rest of the window"
        )

        for _ in 0..<30 { workspace.undo() }
        for _ in 0..<30 { workspace.redo() }
        check(workspace.pdfDocument === document, "Hammering undo and redo closed the document")
        check(workspace.pageCount == 2, "Hammering undo and redo left \(workspace.pageCount) pages")
        check(page.annotations.count == 3, "Hammering undo and redo left \(page.annotations.count) annotations")

        // While an editor is open, Cmd-Z belongs to the text being typed, not to the page.
        workspace.activeTool = .editText
        workspace.beginTextReplacement(at: CGPoint(x: 70, y: 402), on: page)
        guard let replaced = workspace.selectedAnnotation else { fail("No replacement was started") }
        workspace.commitTextReplacement(replaced, text: "Riscritto")
        let annotationsWhileEditing = page.annotations.count
        workspace.beginInlineTextEditing(replaced)
        if view.activeInlineEditor != nil {
            workspace.undo()
            check(
                page.annotations.count == annotationsWhileEditing,
                "Undo changed the page while a text editor was open"
            )
            check(replaced.contents == "Riscritto", "Undo rewound the page text while the editor was open")
        }
        workspace.cancelTextReplacement(replaced)

        print("Undo history smoke test passed.")
    }

    private static func makePDF(pages: Int, in directory: URL) -> URL {
        let url = directory.appendingPathComponent("undo.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
            let attributed = NSAttributedString(string: "Pagina \(index + 1)", attributes: [.font: font])
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
        FileHandle.standardError.write(Data("Undo history smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
