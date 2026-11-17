import AppKit
import PDFKit
import SwiftUI

/// Colours: each tool its own, the highlighter a few sensible ones, and every annotation's
/// colour changeable after it is placed, whatever tool is in hand.
@main
@MainActor
struct ColorSmoke {
    static func main() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-colors-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "it.lucalazzaroni.zzpdf.tests.colors.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)

        let workspace = PDFWorkspace(
            preferences: preferences,
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("R"))
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        window.contentView = view
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(in: directory))
        view.document = workspace.pdfDocument
        view.autoScales = false
        view.scaleFactor = 1
        view.layoutDocumentView()
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }

        // Each tool starts with a colour of its own, and the highlighter's is a highlighter's.
        check(same(preferences.color(for: .highlight), HighlightPalette.yellow), "Highlighting does not start yellow")
        check(same(preferences.color(for: .text), .black), "Text does not start black")

        // Black chosen for text no longer makes the next highlight black. One colour used to
        // be shared by every tool, so it did, and blotted out the line it was meant to mark.
        workspace.activeTool = .text
        workspace.annotationColor = .black
        workspace.activeTool = .select
        guard let line = page.selection(for: CGRect(x: 20, y: 340, width: 200, height: 24)) else {
            fail("The fixture's text could not be selected")
        }
        view.setCurrentSelection(line, animate: false)
        workspace.addMarkup(.highlight)
        guard let highlight = page.annotations.first(where: { $0.isSubtype(.highlight) }) else {
            fail("No highlight was made")
        }
        check(same(highlight.color.withAlphaComponent(1), HighlightPalette.yellow),
              "A highlight made after choosing black text came out \(highlight.color)")
        let strength = highlight.color.alphaComponent
        check(strength < 0.9, "The highlight is opaque and hides its text")

        // An existing highlight can be recoloured, from the palette, keeping its strength —
        // and the highlighter keeps that colour for next time. One undo puts it back.
        workspace.selectAnnotation(highlight)
        check(workspace.selectedAnnotationIsHighlight, "A selected highlight was not recognised")
        check(same(workspace.selectedMarkupColor, HighlightPalette.yellow), "The inspector shows the wrong colour")
        workspace.setSelectedMarkupColor(HighlightPalette.green)
        check(same(highlight.color.withAlphaComponent(1), HighlightPalette.green), "The highlight could not be recoloured")
        check(abs(highlight.color.alphaComponent - strength) < 0.01, "Recolouring changed how strong the highlight is")
        check(same(preferences.color(for: .highlight), HighlightPalette.green), "The highlighter did not keep the new colour")
        check(same(preferences.color(for: .text), .black), "Recolouring a highlight changed the text colour")
        workspace.undo()
        check(same(highlight.color.withAlphaComponent(1), HighlightPalette.yellow), "Undo did not put the yellow back")
        workspace.redo()

        // A highlight belongs to the text under it: grabbing it does not drag it off.
        let highlightBounds = highlight.bounds
        drag(in: view, window: window, page: page,
             from: CGPoint(x: highlightBounds.midX, y: highlightBounds.midY),
             to: CGPoint(x: highlightBounds.midX + 40, y: highlightBounds.midY - 60))
        check(highlight.bounds == highlightBounds, "Dragging the highlight moved it off its text")

        // Text placed with the text tool can be recoloured with that tool still in hand.
        workspace.activeTool = .text
        workspace.textToInsert = "Nota"
        workspace.addAnnotation(at: CGPoint(x: 40, y: 200), on: page)
        guard let text = page.annotations.first(where: { $0.isSubtype(.freeText) }) else { fail("No text was placed") }
        workspace.selectAnnotation(text)
        let blue = Color(.sRGB, red: 0.1, green: 0.3, blue: 0.9)
        workspace.setSelectedTextColor(blue)
        check(same(Color(nsColor: text.fontColor ?? .black), blue), "The placed text could not be recoloured")
        check(same(preferences.color(for: .text), blue), "New text will not come out in the colour just chosen")
        check(same(preferences.color(for: .highlight), HighlightPalette.green), "Recolouring text changed the highlighter")

        // Recolouring a rectangle teaches the rectangle tool, and leaves the line tool alone.
        workspace.activeTool = .rectangle
        workspace.addAnnotation(at: CGPoint(x: 150, y: 150), on: page,
                                dragPoints: [CGPoint(x: 150, y: 150), CGPoint(x: 230, y: 200)])
        let lineBefore = preferences.color(for: .line)
        let purple = Color(.sRGB, red: 0.5, green: 0.2, blue: 0.7)
        workspace.setSelectedDrawingStrokeColor(purple)
        check(same(preferences.color(for: .rectangle), purple), "The rectangle tool did not keep the new colour")
        check(same(preferences.color(for: .line), lineBefore), "Recolouring a rectangle changed the line tool")

        // PDFKit draws each annotation in a layer of its own at a fixed resolution, which is
        // why they looked grainy when zoomed. A stand-in for that layer shows the canvas
        // keeping it at the resolution the zoom needs.
        view.wantsLayer = true
        view.scaleFactor = 3
        let effect = StandInAnnotationEffectLayer()
        effect.frame = CGRect(x: 0, y: 0, width: 60, height: 40)
        effect.contentsScale = 1
        view.layer?.addSublayer(effect)
        view.sharpenAnnotationLayers()
        let backing = window.backingScaleFactor
        check(abs(effect.contentsScale - backing * 3) < 0.01,
              "An annotation's layer is at \(effect.contentsScale)x, not the \(backing * 3)x the zoom needs")
        // A huge one is not raised past the screen's own resolution, rather than being given
        // a bitmap the size of a poster; a smaller one at the same zoom still is.
        let huge = StandInAnnotationEffectLayer()
        huge.frame = CGRect(x: 0, y: 0, width: 6000, height: 6000)
        huge.contentsScale = backing
        view.layer?.addSublayer(huge)
        view.scaleFactor = 5
        view.sharpenAnnotationLayers()
        check(abs(huge.contentsScale - backing) < 0.01, "A page-sized annotation was given \(huge.contentsScale)x")
        check(abs(effect.contentsScale - backing * 5) < 0.01, "Zooming further left a small annotation at \(effect.contentsScale)x")

        print("Color smoke test passed.")
    }

    private static func drag(in view: InteractivePDFView, window: NSWindow, page: PDFPage, from: CGPoint, to: CGPoint) {
        let start = view.convert(view.convert(from, from: page), to: nil)
        let end = view.convert(view.convert(to, from: page), to: nil)
        for (type, point) in [(NSEvent.EventType.leftMouseDown, start), (.leftMouseDragged, end), (.leftMouseUp, end)] {
            guard let event = NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ) else { fail("Mouse events could not be made") }
            switch type {
            case .leftMouseDown: view.mouseDown(with: event)
            case .leftMouseDragged: view.mouseDragged(with: event)
            default: view.mouseUp(with: event)
            }
        }
    }

    private static func same(_ a: Color, _ b: Color) -> Bool {
        same(NSColor(a), NSColor(b))
    }

    private static func same(_ a: NSColor, _ b: Color) -> Bool {
        same(a, NSColor(b))
    }

    private static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("colori.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fail("No PDF context") }
        context.beginPDFPage(nil)
        let line = NSAttributedString(
            string: "Una riga da evidenziare",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
        )
        context.textPosition = CGPoint(x: 24, y: 346)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Color smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}

/// Named the way PDFKit names the layer it draws an annotation in, which is all the canvas
/// has to go on.
final class StandInAnnotationEffectLayer: CALayer {}
