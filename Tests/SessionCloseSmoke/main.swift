import AppKit
import PDFKit

@main
@MainActor
struct SessionCloseSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-session-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let recoveryDirectory = directory.appendingPathComponent("Recovery", isDirectory: true)
        let suiteName = "it.lucalazzaroni.zzpdf.tests.session.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        let first = makePDF(named: "primo", in: directory)
        let second = makePDF(named: "secondo", in: directory)

        // A document that is open is the one restored next launch.
        let workspace = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        workspace.load(first)
        check(
            preferences.lastDocumentURL?.path == first.path,
            "Opening a document did not store it for the next launch"
        )

        // Closing that window on purpose has to forget it, and nothing that happens
        // afterwards may put it back.
        workspace.closeSessionDeliberately(saving: false)
        check(preferences.lastDocumentURL == nil, "A deliberate close still stores the document")
        workspace.recordCurrentPage(1)
        workspace.setPageLayout(.single)
        workspace.fitPage()
        check(
            preferences.lastDocumentURL == nil,
            "A view update after a deliberate close stored the document again"
        )

        // Unsaved edits discarded at close must not come back through the recovery store.
        let dirtyWorkspace = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        dirtyWorkspace.load(second)
        guard let page = dirtyWorkspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }
        dirtyWorkspace.activeTool = .rectangle
        dirtyWorkspace.addAnnotation(
            at: CGPoint(x: 40, y: 40),
            on: page,
            dragPoints: [CGPoint(x: 40, y: 40), CGPoint(x: 140, y: 110)]
        )
        check(dirtyWorkspace.isDirty, "The edited fixture is not marked as edited")
        dirtyWorkspace.flushTemporaryAutosave()
        check(
            TemporaryRecoveryStore(directoryURL: recoveryDirectory).claimLatest() != nil,
            "An edited document did not leave a recovery copy"
        )

        dirtyWorkspace.closeSessionDeliberately(saving: false)
        // "Don't Save" leaves the edits in memory, and the window teardown runs one last
        // autosave flush; neither may recreate the recovery copy.
        dirtyWorkspace.flushTemporaryAutosave()
        dirtyWorkspace.prepareForApplicationTermination()
        check(
            TemporaryRecoveryStore(directoryURL: recoveryDirectory).claimLatest() == nil,
            "A document closed on purpose is still offered for recovery on the next launch"
        )

        // Saving on close keeps the file but still ends the session.
        let saving = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        saving.load(second)
        guard let savingPage = saving.pdfDocument?.page(at: 0) else { fail("The save fixture has no page") }
        saving.activeTool = .rectangle
        saving.addAnnotation(
            at: CGPoint(x: 60, y: 60),
            on: savingPage,
            dragPoints: [CGPoint(x: 60, y: 60), CGPoint(x: 120, y: 100)]
        )
        check(saving.closeSessionDeliberately(saving: true), "Closing while saving reported failure")
        check(!saving.isDirty, "Closing while saving left the document marked as edited")
        check(preferences.lastDocumentURL == nil, "Closing while saving still stores the document")
        check(
            PDFDocument(url: second)?.page(at: 0)?.annotations.isEmpty == false,
            "Closing while saving did not write the annotation to disk"
        )

        // Closing an untitled window must not erase what another window remembered.
        let remembered = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        remembered.load(first)
        check(preferences.lastDocumentURL?.path == first.path, "The second window did not store its document")
        let untitled = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        untitled.closeSessionDeliberately(saving: false)
        check(
            preferences.lastDocumentURL?.path == first.path,
            "Closing an untitled window erased the document another window had stored"
        )

        // Two open documents are both remembered, frontmost first.
        let closed = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        closed.load(second)
        check(
            preferences.sessionDocuments.map(\.path) == [second.path, first.path],
            "Two open documents are stored as \(preferences.sessionDocuments.map(\.path))"
        )

        // Closing one of them leaves the other one alone.
        closed.closeSessionDeliberately(saving: false)
        check(
            preferences.sessionDocuments.map(\.path) == [first.path],
            "Closing one document left \(preferences.sessionDocuments.map(\.path))"
        )
        remembered.rememberSessionForTermination()
        check(
            preferences.lastDocumentURL?.path == first.path,
            "Quitting with a window open did not store its document for the next launch"
        )
        closed.rememberSessionForTermination()
        check(
            preferences.sessionDocuments.map(\.path) == [first.path],
            "A window closed on purpose stored itself again while quitting"
        )

        // The launch plan reopens one window per stored document.
        let openAgain = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
        openAgain.load(second)
        check(
            preferences.sessionDocuments.count == 2,
            "Reopening a document did not put it back in the session"
        )
        let registry = WorkspaceRegistry()
        registry.prepareRestoreQueue(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: recoveryDirectory)
        )
        var restored: [String] = []
        while let item = registry.nextRestoreItem() {
            let window = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
            window.restore(item)
            restored.append(window.fileURL?.path ?? "-")
        }
        check(
            restored == [second.path, first.path],
            "The launch plan reopened \(restored) instead of both documents, frontmost first"
        )

        // A stored document that has been deleted is dropped instead of reopening empty.
        try? FileManager.default.removeItem(at: second)
        let afterDeletion = WorkspaceRegistry()
        afterDeletion.prepareRestoreQueue(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: recoveryDirectory)
        )
        var survivors: [String] = []
        while let item = afterDeletion.nextRestoreItem() {
            let window = makeWorkspace(preferences: preferences, recoveryDirectory: recoveryDirectory)
            window.restore(item)
            if let path = window.fileURL?.path { survivors.append(path) }
        }
        check(survivors == [first.path], "A deleted document was still reopened: \(survivors)")

        print("Session close and restore smoke test passed.")
    }

    private static func makeWorkspace(
        preferences: AppPreferences,
        recoveryDirectory: URL
    ) -> PDFWorkspace {
        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: recoveryDirectory)
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        workspace.pdfView = view
        view.workspace = workspace
        return workspace
    }

    private static func makePDF(named name: String, in directory: URL) -> URL {
        let url = directory.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(
            string: name,
            attributes: [.font: font, .foregroundColor: NSColor.black]
        )
        context.textPosition = CGPoint(x: 30, y: 200)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Session close and restore smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
