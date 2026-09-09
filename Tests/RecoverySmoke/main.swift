import Foundation
import PDFKit

@main
@MainActor
struct RecoverySmokeTest {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-recovery-smoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 200, height: 300), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSColor.black.setFill()
            NSRect(x: 30, y: 30, width: 80, height: 20).fill()
            return true
        }
        guard let page = PDFPage(image: image) else {
            fatalError("Could not create recovery test page")
        }
        document.insert(page, at: 0)

        let identifier = UUID()
        let writer = TemporaryRecoveryStore(directoryURL: directory)
        let originalURL = directory.appendingPathComponent("Original.pdf")
        precondition(writer.write(
            document: document,
            identifier: identifier,
            originalURL: originalURL,
            displayName: "Original",
            pageIndex: 0,
            zoom: 1.25,
            pageLayout: .continuous
        ))
        precondition(!FileManager.default.fileExists(atPath: originalURL.path))

        let restartedStore = TemporaryRecoveryStore(directoryURL: directory)
        guard let (record, recoveredDocument) = restartedStore.claimLatest() else {
            fatalError("Recovery record was not found")
        }
        precondition(record.identifier == identifier)
        precondition(record.originalPath == originalURL.path)
        precondition(record.displayName == "Original")
        precondition(record.zoom == 1.25)
        precondition(record.pageLayout == PageLayoutMode.continuous.rawValue)
        precondition(recoveredDocument.pageCount == 1)

        restartedStore.discard(identifier)
        precondition(restartedStore.claimLatest() == nil)

        let suiteName = "it.lucalazzaroni.zzpdf.tests.recovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.restoreLastDocument = false
        preferences.temporaryAutosave = true

        let workspaceStore = TemporaryRecoveryStore(directoryURL: directory)
        let workspace = PDFWorkspace(preferences: preferences, recoveryStore: workspaceStore)
        workspace.pdfDocument = document
        workspace.fileURL = originalURL
        workspace.changed("Test edit")
        workspace.flushTemporaryAutosave()
        precondition(!FileManager.default.fileExists(atPath: originalURL.path))

        let restoredStore = TemporaryRecoveryStore(directoryURL: directory)
        let restoredWorkspace = PDFWorkspace(preferences: preferences, recoveryStore: restoredStore)
        restoredWorkspace.restorePreviousDocumentIfNeeded()
        precondition(restoredWorkspace.isDirty)
        precondition(restoredWorkspace.pdfDocument?.pageCount == 1)
        precondition(restoredWorkspace.fileURL == nil)
        precondition(restoredWorkspace.statusMessage.contains("Recovered unsaved changes"))
        restoredWorkspace.isDirty = false
        precondition(restoredStore.claimLatest() == nil)

        print("Temporary autosave and recovery smoke test passed.")
    }
}
