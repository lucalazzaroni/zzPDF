import AppKit
import PDFKit

@main
@MainActor
struct DocumentToolsSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-doctools-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.doctools.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        compareDocuments(in: directory)
        roundTripFormData(in: directory, defaults: defaults)
        readSignatures(in: directory)

        print("Document tools smoke test passed.")
    }

    // MARK: - Comparing

    private static func compareDocuments(in directory: URL) {
        let original = makeTextPDF(
            named: "v1",
            in: directory,
            pages: ["Prima pagina invariata", "Seconda pagina originale", "Terza pagina invariata"]
        )
        let revised = makeTextPDF(
            named: "v2",
            in: directory,
            pages: ["Prima pagina invariata", "Seconda pagina RISCRITTA", "Terza pagina invariata", "Quarta pagina aggiunta"]
        )
        guard let left = PDFDocument(url: original), let right = PDFDocument(url: revised) else {
            fail("The comparison fixtures did not open")
        }
        let results = DocumentComparer.compare(left, with: right)
        check(results.count == 4, "The comparison covers \(results.count) pages instead of 4")
        check(results[0].change == .identical, "Page 1 came back as \(results[0].change.label)")
        check(results[1].change == .textChanged, "Page 2 came back as \(results[1].change.label)")
        check(results[2].change == .identical, "Page 3 came back as \(results[2].change.label)")
        check(results[3].change == .added, "Page 4 came back as \(results[3].change.label)")
        check(results.filter(\.change.isChange).count == 2, "The comparison counted the wrong number of changes")

        // A document compared with itself reports nothing at all.
        guard let same = PDFDocument(url: original) else { fail("The fixture did not reopen") }
        let unchanged = DocumentComparer.compare(left, with: same)
        check(
            unchanged.allSatisfy { $0.change == .identical },
            "Comparing a document with itself found \(unchanged.filter(\.change.isChange).count) changes"
        )

        // A page whose text matches but whose ink moved is caught by the rendering pass.
        let moved = makeShapePDF(named: "moved", in: directory, offset: 40)
        let still = makeShapePDF(named: "still", in: directory, offset: 0)
        guard let a = PDFDocument(url: still), let b = PDFDocument(url: moved) else {
            fail("The drawing fixtures did not open")
        }
        let visual = DocumentComparer.compare(a, with: b)
        check(
            visual.first?.change == .appearanceChanged,
            "A page that only looks different came back as \(visual.first?.change.label ?? "nothing")"
        )
        check(
            (visual.first?.changedFraction ?? 0) > DocumentComparer.appearanceThreshold,
            "The changed area was measured as \(visual.first?.changedFraction ?? 0)"
        )

        // The preview marks the difference rather than coming back empty.
        check(
            DocumentComparer.differenceImage(a.page(at: 0), b.page(at: 0)) != nil,
            "The difference preview came back empty"
        )
        check(
            DocumentComparer.differenceImage(nil, b.page(at: 0)) != nil,
            "An added page has no preview"
        )
    }

    // MARK: - Form data

    private static func roundTripFormData(in directory: URL, defaults: UserDefaults) {
        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.pdfDocument = makeFormDocument()
        view.document = workspace.pdfDocument

        check(workspace.hasFormFields, "The form fixture reports no fields")
        var values = workspace.formFieldValues()
        check(values["nome"] == "Luca", "The name field reads \(values["nome"] ?? "nothing")")
        check(values["accetto"] == "Off", "The checkbox reads \(values["accetto"] ?? "nothing")")

        let file = directory.appendingPathComponent("form.json")
        check(workspace.writeFormData(to: file), "The form data was not written")

        // Change everything, then fill it back in from the file.
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The form fixture has no page") }
        for annotation in page.annotations where annotation.isSubtype(.widget) {
            if annotation.widgetFieldType == .text { annotation.widgetStringValue = "" }
            if annotation.widgetFieldType == .button { annotation.buttonWidgetState = .onState }
        }
        check(workspace.formFieldValues()["nome"] == "", "The field was not cleared")

        let filled = workspace.applyFormData(from: file)
        check(filled == 2, "Filling in applied \(filled) fields instead of 2")
        values = workspace.formFieldValues()
        check(values["nome"] == "Luca", "Filling in left the name as \(values["nome"] ?? "nothing")")
        check(values["accetto"] == "Off", "Filling in left the checkbox as \(values["accetto"] ?? "nothing")")

        // It is one undo step, and a file that matches nothing changes nothing.
        workspace.undo()
        check(workspace.formFieldValues()["nome"] == "", "Undo did not take the form back")
        workspace.redo()
        check(workspace.formFieldValues()["nome"] == "Luca", "Redo did not fill the form again")

        let unrelated = directory.appendingPathComponent("altro.json")
        try! Data(#"{"campo-che-non-esiste":"x"}"#.utf8).write(to: unrelated)
        check(workspace.applyFormData(from: unrelated) == 0, "An unrelated file changed fields anyway")
    }

    // MARK: - Signatures

    private static func readSignatures(in directory: URL) {
        let plain = makeTextPDF(named: "plain", in: directory, pages: ["Nessuna firma"])
        guard let document = PDFDocument(url: plain) else { fail("The plain fixture did not open") }
        check(
            DigitalSignatureScanner.signatures(in: document).isEmpty,
            "An unsigned document was reported as signed"
        )

        // A signature dictionary as it appears in a signed file.
        let signed = """
        %PDF-1.7
        7 0 obj
        << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /ETSI.CAdES.detached
           /Name (Mario Rossi) /Reason (Approvazione) /M (D:20260214103000+01'00')
           /ByteRange [0 1234 5678 9012] /Contents <3082> >>
        endobj
        """
        let signatures = DigitalSignatureScanner.signatures(in: Data(signed.utf8))
        check(signatures.count == 1, "Found \(signatures.count) signatures instead of 1")
        guard let signature = signatures.first else { fail("No signature was read") }
        check(signature.signer == "Mario Rossi", "The signer reads \(signature.signer ?? "nothing")")
        check(signature.reason == "Approvazione", "The reason reads \(signature.reason ?? "nothing")")
        check(signature.scheme == "ETSI.CAdES.detached", "The scheme reads \(signature.scheme)")
        check(signature.schemeLabel.contains("PAdES"), "The scheme is labelled \(signature.schemeLabel)")
        guard let date = signature.signedAt else { fail("The signing date was not read") }
        let components = Calendar(identifier: .gregorian).dateComponents(
            in: TimeZone(secondsFromGMT: 0)!,
            from: date
        )
        check(
            components.year == 2026 && components.month == 2 && components.day == 14,
            "The signing date reads \(date)"
        )
    }

    // MARK: - Fixtures

    private static func makeTextPDF(named name: String, in directory: URL, pages: [String]) -> URL {
        let url = directory.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for text in pages {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
            let attributed = NSAttributedString(string: text, attributes: [.font: font])
            context.textPosition = CGPoint(x: 40, y: 300)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func makeShapePDF(named name: String, in directory: URL, offset: CGFloat) -> URL {
        let url = directory.appendingPathComponent("\(name).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.black.cgColor)
        context.fill(CGRect(x: 40 + offset, y: 120, width: 120, height: 90))
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func makeFormDocument() -> PDFDocument {
        let image = NSImage(size: NSSize(width: 400, height: 500))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 400, height: 500)).fill()
        image.unlockFocus()
        let document = PDFDocument()
        guard let page = PDFPage(image: image) else { fail("The form page could not be made") }

        let text = PDFAnnotation(bounds: CGRect(x: 40, y: 400, width: 220, height: 28), forType: .widget, withProperties: nil)
        text.widgetFieldType = .text
        text.fieldName = "nome"
        text.widgetStringValue = "Luca"
        page.addAnnotation(text)

        let check = PDFAnnotation(bounds: CGRect(x: 40, y: 340, width: 22, height: 22), forType: .widget, withProperties: nil)
        check.widgetFieldType = .button
        check.widgetControlType = PDFWidgetControlType(rawValue: 2)!
        check.fieldName = "accetto"
        check.buttonWidgetState = .offState
        page.addAnnotation(check)

        document.insert(page, at: 0)
        return document
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Document tools smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
