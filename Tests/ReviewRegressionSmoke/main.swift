import AppKit
import PDFKit

@main
@MainActor
struct ReviewRegressionSmoke {
    static func main() async {
        var failures: [String] = []
        func check(_ value: Bool, _ message: String) {
            if !value { failures.append(message) }
        }

        // Tj/TJ advance the text cursor using font metrics. Deleting their operands
        // without tracking that advance can delete or shift the next, unrelated run.
        let continuedRuns = Data("BT /F1 12 Tf 1 0 0 1 30 100 Tm (EDIT) Tj ( KEEP) Tj ET".utf8)
        let conservative = ContentStreamEditor.removingText(
            inside: [CGRect(x: 25, y: 95, width: 35, height: 20)], fromStream: continuedRuns)
        check(conservative == continuedRuns, "Unpositioned text runs were destructively edited without font advances")

        // A crop box is in original page coordinates. Repeated undo/redo must not
        // accumulate offsets in notes, form widgets, or drawings.
        let original = PDFPage()
        original.setBounds(CGRect(x: 0, y: 0, width: 400, height: 500), for: .mediaBox)
        original.setBounds(CGRect(x: 30, y: 40, width: 300, height: 400), for: .cropBox)
        let rewritten = PDFPage()
        rewritten.setBounds(CGRect(x: 0, y: 0, width: 300, height: 400), for: .mediaBox)
        let initial = CGRect(x: 70, y: 100, width: 80, height: 20)
        let note = PDFAnnotation(bounds: initial, forType: .text, withProperties: nil)
        original.addAnnotation(note)
        for _ in 0..<3 {
            TextReplacementWriter.transferAnnotations(from: original, to: rewritten)
            check(note.bounds == initial.offsetBy(dx: -30, dy: -40), "Redo moved an annotation on a cropped page")
            TextReplacementWriter.transferAnnotations(from: rewritten, to: original)
            check(note.bounds == initial, "Undo did not restore annotation coordinates on a cropped page")
        }

        // A redacted page that cannot be rendered must reject the entire export.
        // Otherwise a successful-looking file can still contain the redacted words.
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = CGContext(consumer: CGDataConsumer(data: data as CFMutableData)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.textPosition = CGPoint(x: 30, y: 100)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "PRIVATE", attributes: [.font: NSFont.systemFont(ofSize: 14)])), context)
        context.endPDFPage()
        context.closePDF()
        let document = PDFDocument(data: data as Data)!
        let page = document.page(at: 0)!
        let redaction = PDFAnnotation(bounds: CGRect(x: 25, y: 95, width: 140, height: 25), forType: .square, withProperties: nil)
        redaction.contents = RedactionFlattener.marker
        redaction.color = .black
        redaction.interiorColor = .black
        page.addAnnotation(redaction)
        page.setBounds(CGRect(x: 0, y: 0, width: 0.5, height: 0.5), for: .cropBox)
        check(RedactionFlattener.rasterizingRedactedPages(of: document) == nil,
              "A failed redaction render returned a partially flattened document")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("zzpdf-review-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suite = "it.lucalazzaroni.zzpdf.tests.review.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let workspace = PDFWorkspace(preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery")))
        let output = directory.appendingPathComponent("export.pdf")
        let sentinel = Data("Existing file must survive a failed export".utf8)
        try! sentinel.write(to: output)
        check(!workspace.writeFlattenedCopy(of: document, to: output, extraOptions: [:]),
              "An unsafe flattened export reported success")
        check((try? Data(contentsOf: output)) == sentinel,
              "A failed redaction export overwrote the destination")
        check(!workspace.writeFlattenedCopy(of: document, to: output, extraOptions: [.ownerPasswordOption: "test-password"]),
              "A protected export bypassed a failed redaction")

        page.setBounds(box, for: .cropBox)
        check(workspace.writeFlattenedCopy(of: document, to: output, extraOptions: [:]), "Valid redaction export failed")
        let reopened = PDFDocument(url: output)
        check(reopened?.pageCount == 1 && reopened?.findString("PRIVATE", withOptions: []).isEmpty == true,
              "A successful redaction export retained searchable private text")

        let snapshot = data as Data
        let comparison = await DocumentComparer.compareSnapshots(snapshot, with: snapshot)
        check(comparison?.count == 1 && comparison?.first?.change == .identical,
              "Background comparison did not preserve identical-document results")
        let invalidComparison = await DocumentComparer.compareSnapshots(Data("invalid".utf8), with: snapshot)
        check(invalidComparison == nil, "Invalid comparison input reported success")

        if !failures.isEmpty {
            for failure in failures { print("FAIL: \(failure)") }
            exit(1)
        }
        print("Review regressions passed: cropped-page annotation undo/redo, failed-redaction export and background comparison.")
    }
}
