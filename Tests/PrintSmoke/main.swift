import AppKit
import CoreGraphics
import PDFKit

@main
struct PrintSmoke {
    @MainActor
    static func main() {
        let suiteName = "it.lucalazzaroni.zzpdf.tests.print.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: nil, nil) else {
            fatalError("Could not create the print test PDF.")
        }
        let mediaBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        context.beginPDFPage([kCGPDFContextMediaBox as String: mediaBox] as CFDictionary)
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else {
            fatalError("Could not open the print test PDF.")
        }

        let preferences = AppPreferences(defaults: defaults)
        preferences.temporaryAutosave = false
        let workspace = PDFWorkspace(preferences: preferences)
        workspace.pdfDocument = document

        guard let operation = workspace.makePrintOperation() else {
            fatalError("The native print operation was not created.")
        }
        guard operation.showsPrintPanel, operation.showsProgressPanel else {
            fatalError("The native print panels are not enabled.")
        }

        print("Native PDF print-operation smoke test passed.")
    }
}
