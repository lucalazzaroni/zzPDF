import AppKit
import PDFKit

@main
@MainActor
struct DrawingToolsSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-tools-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.tools.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(in: directory))
        view.document = workspace.pdfDocument
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }

        // A line keeps the ends where they were drawn. PDFKit reads them relative to the
        // annotation's own box, so an absolute start point would render nothing.
        let start = CGPoint(x: 60, y: 90)
        let end = CGPoint(x: 220, y: 170)
        workspace.activeTool = .line
        workspace.addAnnotation(at: start, on: page, dragPoints: [start, end])
        guard let line = page.annotations.first(where: { $0.isSubtype(.line) }) else {
            fail("The line tool added nothing")
        }
        check(
            near(CGPoint(x: line.bounds.minX + line.startPoint.x, y: line.bounds.minY + line.startPoint.y), start),
            "The line starts at \(line.startPoint) inside \(line.bounds)"
        )
        check(
            near(CGPoint(x: line.bounds.minX + line.endPoint.x, y: line.bounds.minY + line.endPoint.y), end),
            "The line ends at \(line.endPoint) inside \(line.bounds)"
        )
        check(line.endLineStyle == .none, "A plain line grew an arrowhead")
        check(line.bounds.contains(start) && line.bounds.contains(end), "The line's box does not hold its ends")

        // The arrow is the same annotation with a head on the end the drag finished at.
        workspace.activeTool = .arrow
        workspace.addAnnotation(at: start, on: page, dragPoints: [start, CGPoint(x: 300, y: 60)])
        let arrows = page.annotations.filter { $0.isSubtype(.line) && $0.endLineStyle == .closedArrow }
        check(arrows.count == 1, "The arrow tool produced \(arrows.count) arrows")

        // A click that goes nowhere must not leave a zero-length line behind.
        let linesBefore = page.annotations.filter { $0.isSubtype(.line) }.count
        workspace.addAnnotation(at: start, on: page, dragPoints: [start, start])
        check(
            page.annotations.filter { $0.isSubtype(.line) }.count == linesBefore,
            "A click with no drag added a line"
        )

        // A closed polygon returns to its first corner.
        let corners = [
            CGPoint(x: 60, y: 300),
            CGPoint(x: 160, y: 340),
            CGPoint(x: 120, y: 420)
        ]
        workspace.activeTool = .polygon
        workspace.addPolygon(points: corners, on: page, closed: true)
        guard let polygon = workspace.selectedAnnotation as? ScalableInkAnnotation else {
            fail("The polygon tool did not add scalable ink")
        }
        check(
            polygon.bounds.width > 90 && polygon.bounds.height > 110,
            "The polygon's box is \(polygon.bounds.size)"
        )
        workspace.undo()
        check(
            !page.annotations.contains(polygon),
            "Undoing the polygon left it on the page"
        )

        // Highlight strength follows the preference and never blots the text out in black.
        preferences.highlightOpacity = 0.3
        workspace.annotationColor = .black
        let tint = workspace.nsAnnotationColor.highlightTint(alpha: preferences.highlightOpacity)
        check(abs(tint.alphaComponent - 0.3) < 0.01, "The highlight is \(tint.alphaComponent) opaque instead of 0.3")
        check(
            tint.usingColorSpace(.deviceRGB)!.saturationComponent > 0.3,
            "A black annotation color produced a black highlight rather than falling back to yellow"
        )

        // Changing the font of a replacement keeps it on its baseline. The controls act on
        // the edit while it is open: once committed, the text is page content and has no
        // annotation left to restyle.
        workspace.activeTool = .editText
        workspace.beginTextReplacement(at: CGPoint(x: 70, y: 462), on: page)
        guard let replaced = workspace.selectedAnnotation else { fail("Nothing was picked up to replace") }
        workspace.previewTextEdit("Nuovo")
        let baseline = FreeTextLayout.baseline(of: replaced) ?? 0
        workspace.setSelectedTextFontFamily("Times New Roman")
        check(
            replaced.font?.familyName == "Times New Roman",
            "The font is \(replaced.font?.familyName ?? "nil") instead of Times New Roman"
        )
        check(
            abs((FreeTextLayout.baseline(of: replaced) ?? 0) - baseline) < 0.05,
            "Changing the font moved the baseline to \(FreeTextLayout.baseline(of: replaced) ?? 0)"
        )
        workspace.toggleSelectedTextTrait(bold: true)
        check(workspace.selectedTextIsBold, "Bold did not take")
        check(
            abs((FreeTextLayout.baseline(of: replaced) ?? 0) - baseline) < 0.05,
            "Going bold moved the baseline"
        )
        workspace.toggleSelectedTextTrait(bold: true)
        check(!workspace.selectedTextIsBold, "Bold did not toggle back off")
        check(
            replaced.font?.familyName == "Times New Roman",
            "Toggling bold lost the chosen family"
        )

        // Committing writes it into the page in the font that was chosen, and carries the
        // drawings already on the page across to the rewritten one rather than flattening
        // them into it.
        let drawingsBefore = page.annotations.filter { !TextEditMarker.isTextEdit($0) }.count
        check(drawingsBefore > 0, "The fixture has no drawings to carry over")
        workspace.commitTextReplacement(replaced, text: "Nuovo")
        guard let rewritten = workspace.pdfDocument?.page(at: 0) else { fail("The page is gone") }
        check(
            !rewritten.annotations.contains(where: TextEditMarker.isTextEdit),
            "Committing left the edit's own annotations on the page"
        )
        check(
            rewritten.annotations.count == drawingsBefore,
            "The page came back with \(rewritten.annotations.count) drawings instead of \(drawingsBefore)"
        )
        check((rewritten.string ?? "").contains("Nuovo"), "The replacement is not on the page")
        workspace.undo()
        check(
            !((workspace.pdfDocument?.page(at: 0)?.string ?? "").contains("Nuovo")),
            "Undo left the replacement on the page"
        )
        workspace.redo()

        // Exports.
        workspace.selectPage(0)
        let imageFolder = directory.appendingPathComponent("images", isDirectory: true)
        try! FileManager.default.createDirectory(at: imageFolder, withIntermediateDirectories: true)
        check(workspace.writePageImages(to: imageFolder, dpi: 96) == 1, "Exporting one page as an image failed")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: imageFolder.path)) ?? []
        check(files.count == 1 && files[0].hasSuffix(".png"), "The image export wrote \(files)")

        let smaller = directory.appendingPathComponent("smaller.pdf")
        check(workspace.writeSmallerCopy(to: smaller), "The smaller copy was not written")
        check(PDFDocument(url: smaller)?.pageCount == 1, "The smaller copy is not a readable PDF")

        print("Drawing tools and export smoke test passed.")
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 0.6 && abs(a.y - b.y) < 0.6
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("tools.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 360, height: 520)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 15, nil)
        let attributed = NSAttributedString(string: "Riga da sostituire", attributes: [.font: font])
        context.textPosition = CGPoint(x: 50, y: 460)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Drawing tools smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
