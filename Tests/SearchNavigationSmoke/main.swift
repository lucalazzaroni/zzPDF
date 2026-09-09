import AppKit
import CoreGraphics
import PDFKit

@main
struct SearchNavigationSmoke {
    @MainActor
    static func main() {
        let suiteName = "it.lucalazzaroni.zzpdf.tests.search.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.temporaryAutosave = false
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            fatalError("Could not create the search test PDF.")
        }

        let mediaBox = CGRect(x: 0, y: 0, width: 400, height: 500)
        for pageNumber in 1...3 {
            context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let text = "Search target needle on page \(pageNumber)" as NSString
            text.draw(
                at: CGPoint(x: 48, y: 250),
                withAttributes: [.font: NSFont.systemFont(ofSize: 20), .foregroundColor: NSColor.black]
            )
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            fatalError("Could not open the search test PDF.")
        }
        let workspace = PDFWorkspace(preferences: preferences)
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        workspace.pdfDocument = document
        workspace.pdfView = view
        view.workspace = workspace
        view.document = document
        view.displayMode = .singlePage

        workspace.searchText = "needle"
        workspace.submitSearch(direction: 1)
        guard workspace.searchResults.count == 3,
              workspace.searchIndex == 0,
              workspace.currentPageIndex == 0 else {
            fatalError("The initial search result was not revealed.")
        }

        workspace.submitSearch(direction: 1)
        guard workspace.searchIndex == 1,
              workspace.currentPageIndex == 1,
              view.currentPage === document.page(at: 1) else {
            fatalError("Return did not reveal the next search result.")
        }

        workspace.submitSearch(direction: -1)
        guard workspace.searchIndex == 0,
              workspace.currentPageIndex == 0,
              view.currentPage === document.page(at: 0) else {
            fatalError("Shift-Return did not reveal the previous search result.")
        }

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-session-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        guard document.write(to: temporaryURL) else {
            fatalError("Could not write the session restoration fixture.")
        }
        preferences.restoreLastDocument = true
        preferences.rememberDocument(temporaryURL, pageIndex: 2, zoom: 1.25, layout: .single)
        let restoredWorkspace = PDFWorkspace(preferences: preferences)
        restoredWorkspace.restorePreviousDocumentIfNeeded()
        let restoredView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        restoredWorkspace.attachPDFView(restoredView)
        restoredView.workspace = restoredWorkspace
        restoredView.document = restoredWorkspace.pdfDocument
        restoredWorkspace.applyPendingViewRestoration()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        guard restoredWorkspace.currentPageIndex == 2,
              restoredWorkspace.pageLayout == .single,
              restoredView.currentPage === restoredWorkspace.pdfDocument?.page(at: 2),
              abs(restoredView.scaleFactor - 1.25) < 0.01 else {
            fatalError("The previous PDF view state was not restored.")
        }

        print("Search navigation and session restoration smoke test passed.")
    }
}
