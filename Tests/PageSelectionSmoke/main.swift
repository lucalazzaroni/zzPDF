import AppKit
import PDFKit

@main
@MainActor
struct PageSelectionSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-pages-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.pages.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.confirmPageDeletion = false

        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(pages: 6, in: directory))
        view.document = workspace.pdfDocument
        let original = labels(workspace)
        check(
            original == (1...6).map { "Pagina \($0)" },
            "The fixture reads \(original)"
        )

        // Selecting a page replaces the selection; a range extends it.
        workspace.selectPage(1)
        check(workspace.selectedPageIndexes == [1], "Selecting a page left \(workspace.selectedPageIndexes)")
        workspace.extendPageSelection(to: 3)
        check(workspace.selectedPageIndexes == [1, 2, 3], "Extending left \(workspace.selectedPageIndexes)")
        workspace.togglePageSelection(2)
        check(workspace.selectedPageIndexes == [1, 3], "Toggling left \(workspace.selectedPageIndexes)")
        workspace.togglePageSelection(2)
        check(workspace.targetPageIndexes == [1, 2, 3], "The action target is \(workspace.targetPageIndexes)")

        // Rotating applies to every selected page and undoes in one step.
        workspace.rotateSelectedPages(by: 90)
        check(
            rotations(workspace) == [0, 90, 90, 90, 0, 0],
            "Rotating the selection produced \(rotations(workspace))"
        )
        workspace.undo()
        check(rotations(workspace) == [0, 0, 0, 0, 0, 0], "Undo left \(rotations(workspace))")

        // Duplicating three pages inserts three copies, and undo removes all of them.
        workspace.selectPage(1)
        workspace.extendPageSelection(to: 3)
        workspace.duplicateSelectedPages()
        check(
            labels(workspace) == ["Pagina 1", "Pagina 2", "Pagina 2", "Pagina 3", "Pagina 3",
                                  "Pagina 4", "Pagina 4", "Pagina 5", "Pagina 6"],
            "Duplicating the selection produced \(labels(workspace))"
        )
        workspace.undo()
        check(labels(workspace) == original, "Undoing the duplication left \(labels(workspace))")

        // Deleting several pages at once, and putting them back.
        workspace.selectPage(1)
        workspace.extendPageSelection(to: 3)
        workspace.deleteSelectedPages()
        check(labels(workspace) == ["Pagina 1", "Pagina 5", "Pagina 6"], "Deleting the selection produced \(labels(workspace))")
        workspace.undo()
        check(labels(workspace) == original, "Undoing the deletion left \(labels(workspace))")
        workspace.redo()
        check(labels(workspace) == ["Pagina 1", "Pagina 5", "Pagina 6"], "Redoing the deletion left \(labels(workspace))")
        workspace.undo()

        // The document always keeps a page.
        workspace.selectedPageIndexes = Set(0..<workspace.pageCount)
        workspace.deleteSelectedPages()
        check(workspace.pageCount == 6, "Deleting every page emptied the document")

        // Dragging a thumbnail to a new position reorders, and undo puts it back.
        workspace.reorderPage(from: 0, to: 4)
        check(labels(workspace) == ["Pagina 2", "Pagina 3", "Pagina 4", "Pagina 5", "Pagina 1", "Pagina 6"], "Reordering produced \(labels(workspace))")
        check(workspace.currentPageIndex == 4, "The moved page is not the current one")
        workspace.undo()
        check(labels(workspace) == original, "Undoing the reorder left \(labels(workspace))")

        // Extracting writes exactly the selected pages, in order.
        workspace.selectPage(4)
        workspace.togglePageSelection(1)
        let extracted = directory.appendingPathComponent("extract.pdf")
        check(workspace.writeSelectedPages(to: extracted), "Extracting the selection failed")
        guard let output = PDFDocument(url: extracted) else { fail("The extracted file could not be opened") }
        let extractedLabels = (0..<output.pageCount).map { index in
            (output.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        check(extractedLabels == ["Pagina 2", "Pagina 5"], "The extracted file holds \(extractedLabels)")

        // The annotation list finds what has been added, and hides the redaction backdrop.
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }
        workspace.activeTool = .note
        workspace.addAnnotation(at: CGPoint(x: 60, y: 300), on: page)
        workspace.commitNoteEditing(text: "Da rivedere")
        workspace.activeTool = .editText
        let textPoint = CGPoint(x: 70, y: 404)
        guard workspace.replaceableText(at: textPoint, on: page) != nil else {
            fail("No page text was found at \(textPoint), where the fixture draws its label")
        }
        workspace.beginTextReplacement(at: textPoint, on: page)
        guard let replaced = workspace.selectedAnnotation else { fail("The replacement was not started") }
        workspace.commitTextReplacement(replaced, text: "Uno")
        let entries = workspace.annotationEntries()
        check(entries.count == 2, "The annotation list holds \(entries.count) rows instead of 2")
        check(
            entries.contains { $0.summary == "Da rivedere" && $0.kind == "Note" },
            "The note is missing from the annotation list"
        )
        check(
            entries.contains { $0.kind == "Replaced text" },
            "The replaced text is missing from the annotation list"
        )
        check(
            entries.allSatisfy { $0.pageIndex == 0 },
            "The annotation list reports the wrong page"
        )

        // Splitting writes one file per part, covering every page exactly once.
        workspace.splitEveryPages = 2
        workspace.splitAtContents = false
        check(workspace.splitStartIndexes == [0, 2, 4], "The cuts fall at \(workspace.splitStartIndexes)")
        let splitFolder = directory.appendingPathComponent("split", isDirectory: true)
        try! FileManager.default.createDirectory(at: splitFolder, withIntermediateDirectories: true)
        check(workspace.writeSplitParts(into: splitFolder) == 3, "Splitting did not write three files")
        let parts = ((try? FileManager.default.contentsOfDirectory(atPath: splitFolder.path)) ?? []).sorted()
        check(parts.count == 3, "The split folder holds \(parts)")
        var recovered: [String] = []
        for part in parts {
            guard let document = PDFDocument(url: splitFolder.appendingPathComponent(part)) else {
                fail("A split part could not be opened")
            }
            check(document.pageCount == 2, "\(part) holds \(document.pageCount) pages instead of 2")
            for index in 0..<document.pageCount {
                recovered.append((document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        check(recovered == labels(workspace), "The parts hold \(recovered) instead of \(labels(workspace))")

        // An odd remainder still gets its own part rather than being dropped.
        workspace.splitEveryPages = 4
        check(workspace.splitStartIndexes == [0, 4], "A remainder changed the cuts to \(workspace.splitStartIndexes)")

        print("Page selection and annotation list smoke test passed.")
    }

    private static func labels(_ workspace: PDFWorkspace) -> [String] {
        guard let document = workspace.pdfDocument else { return [] }
        return (0..<document.pageCount).map { index in
            (document.page(at: index)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func rotations(_ workspace: PDFWorkspace) -> [Int] {
        guard let document = workspace.pdfDocument else { return [] }
        return (0..<document.pageCount).map { document.page(at: $0)?.rotation ?? -1 }
    }

    private static func makePDF(pages: Int, in directory: URL) -> URL {
        let url = directory.appendingPathComponent("pages.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 420)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
            let attributed = NSAttributedString(string: "Pagina \(index + 1)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 40, y: 400)
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
        FileHandle.standardError.write(Data("Page selection smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
