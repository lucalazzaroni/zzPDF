import AppKit
import PDFKit
import SwiftUI

/// Changing a drawing after it is placed: its outline, and its size and shape by hand.
///
/// Placed rectangles could not have their border recoloured at all; lines, arrows and
/// freehand drawings could not be changed in any way. Reshaping took the four corners of
/// the selection and nothing else, only after going back to Select, with no sign under
/// the pointer that anything could be grabbed — and stretching a line by its box clipped
/// it rather than moving its ends.
///
/// Everything here goes through the canvas the way the reader does, with mouse events, in
/// a window that is never put on screen.
@main
@MainActor
struct ShapeEditingSmoke {
    static func main() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-shapes-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "it.lucalazzaroni.zzpdf.tests.shapes.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("R"))
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 600),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 600))
        window.contentView = view
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(in: directory))
        view.document = workspace.pdfDocument
        view.autoScales = false
        view.scaleFactor = 1
        view.layoutDocumentView()
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }

        func drag(_ from: CGPoint, _ to: CGPoint) {
            let start = view.convert(view.convert(from, from: page), to: nil)
            let end = view.convert(view.convert(to, from: page), to: nil)
            guard let down = event(.leftMouseDown, at: start, in: window),
                  let mid = event(.leftMouseDragged, at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), in: window),
                  let moved = event(.leftMouseDragged, at: end, in: window),
                  let up = event(.leftMouseUp, at: end, in: window) else { fail("Mouse events could not be made") }
            view.mouseDown(with: down)
            view.mouseDragged(with: mid)
            view.mouseDragged(with: moved)
            view.mouseUp(with: up)
        }
        func squares() -> [PDFAnnotation] { page.annotations.filter { $0.isSubtype(.square) } }

        // A rectangle drawn with the rectangle tool is selected, and is a drawing whose
        // outline can be changed.
        workspace.activeTool = .rectangle
        drag(CGPoint(x: 100, y: 300), CGPoint(x: 200, y: 360))
        guard let rectangle = squares().first, squares().count == 1 else { fail("Dragging drew \(squares().count) rectangles") }
        check(workspace.selectedAnnotation === rectangle, "The new rectangle was not selected")
        check(workspace.selectedAnnotationIsDrawing, "A rectangle was not taken for a drawing")

        // Its border can be recoloured, which it could not be before. The colour picker
        // reports every step of a drag, and taking the change back is still one step.
        let originalColour = rectangle.color
        workspace.setSelectedDrawingStrokeColor(.red)
        workspace.setSelectedDrawingStrokeColor(.blue)
        workspace.setSelectedDrawingStrokeColor(.green)
        check(same(rectangle.color, NSColor(Color.green)), "The border is \(rectangle.color) instead of green")
        check(same(NSColor(workspace.annotationColor), NSColor(Color.green)), "The next drawing will not be green")
        workspace.undo()
        check(same(rectangle.color, originalColour), "One undo did not take the colour change back: \(rectangle.color)")
        workspace.redo()
        check(same(rectangle.color, NSColor(Color.green)), "Redo did not put the green back")

        // The right edge is a handle too, not just the corners, and it works with the
        // rectangle tool still in hand. Only the width changes.
        let before = rectangle.bounds
        drag(CGPoint(x: before.maxX + 3, y: before.midY), CGPoint(x: before.maxX + 43, y: before.midY))
        check(abs(rectangle.bounds.width - (before.width + 40)) < 1.5, "The right edge made the width \(rectangle.bounds.width)")
        check(abs(rectangle.bounds.height - before.height) < 0.5, "Dragging the right edge changed the height")
        check(squares().count == 1, "Reshaping the rectangle drew another one")
        workspace.undo()
        check(rectangle.bounds == before, "Undo did not put the rectangle back to \(before)")

        // And so is the top edge.
        drag(CGPoint(x: before.midX, y: before.maxY + 3), CGPoint(x: before.midX, y: before.maxY + 23))
        check(abs(rectangle.bounds.height - (before.height + 20)) < 1.5, "The top edge made the height \(rectangle.bounds.height)")
        check(abs(rectangle.bounds.width - before.width) < 0.5, "Dragging the top edge changed the width")
        workspace.undo()

        // Grabbing it inside moves it, with the tool still in hand, instead of starting a
        // second rectangle on top of it.
        drag(CGPoint(x: before.midX, y: before.midY), CGPoint(x: before.midX + 30, y: before.midY - 20))
        check(squares().count == 1, "Grabbing the rectangle drew another one")
        check(
            abs(rectangle.bounds.minX - (before.minX + 30)) < 1 && abs(rectangle.bounds.minY - (before.minY - 20)) < 1,
            "The rectangle moved to \(rectangle.bounds.origin) instead of by (30, -20)"
        )
        workspace.undo()

        // A line is reshaped by its ends. Stretching its box moved nothing and clipped it.
        workspace.activeTool = .line
        drag(CGPoint(x: 60, y: 120), CGPoint(x: 180, y: 120))
        guard let line = page.annotations.first(where: { $0.isSubtype(.line) }) else { fail("No line was drawn") }
        check(workspace.selectedAnnotation === line, "The new line was not selected")
        check(workspace.selectedAnnotationIsDrawing, "A line was not taken for a drawing")
        let ends = workspace.lineEndpoints(of: line)
        check(near(ends.start, CGPoint(x: 60, y: 120)) && near(ends.end, CGPoint(x: 180, y: 120)),
              "The line runs from \(ends.start) to \(ends.end)")
        drag(ends.end, CGPoint(x: 180, y: 200))
        let reshaped = workspace.lineEndpoints(of: line)
        check(near(reshaped.end, CGPoint(x: 180, y: 200)), "Dragging the end left it at \(reshaped.end)")
        check(near(reshaped.start, ends.start), "Dragging one end moved the other to \(reshaped.start)")
        check(line.bounds.contains(reshaped.end) && line.bounds.contains(reshaped.start),
              "The line's box no longer holds its ends, so it is clipped")
        workspace.undo()
        check(near(workspace.lineEndpoints(of: line).end, ends.end), "Undo did not put the end back")

        // A line's colour and width can be changed after it is drawn, and a thicker line
        // gets room for itself rather than being clipped.
        workspace.setSelectedDrawingStrokeColor(.orange)
        check(same(line.color, NSColor(Color.orange)), "The line could not be recoloured")
        workspace.beginSelectedShapeStrokeChange()
        workspace.previewSelectedShapeStrokeWidth(8)
        workspace.endSelectedShapeStrokeChange()
        check(line.border?.lineWidth == 8, "The line's width is \(line.border?.lineWidth ?? 0) instead of 8")
        check(near(workspace.lineEndpoints(of: line).start, ends.start), "Thickening the line moved it")
        check(line.bounds.insetBy(dx: 31, dy: 31).contains(ends.start), "A thicker line kept a box too tight for it")

        // Freehand drawing follows its width too, which it kept to itself before.
        workspace.activeTool = .draw
        drag(CGPoint(x: 60, y: 450), CGPoint(x: 160, y: 500))
        guard let ink = workspace.selectedAnnotation as? ScalableInkAnnotation else { fail("No freehand drawing was selected") }
        workspace.beginSelectedShapeStrokeChange()
        workspace.previewSelectedShapeStrokeWidth(6)
        workspace.endSelectedShapeStrokeChange()
        check(ink.strokeWidth == 6, "The drawing kept a stroke of \(ink.strokeWidth)")

        // A redaction is not a drawing to restyle: its black is the point of it.
        workspace.activeTool = .redact
        drag(CGPoint(x: 220, y: 450), CGPoint(x: 280, y: 480))
        check(!workspace.selectedAnnotationIsDrawing, "A redaction was offered for restyling")

        print("Shape editing smoke test passed.")
    }

    private static func same(_ a: NSColor, _ b: NSColor) -> Bool {
        guard let a = a.usingColorSpace(.sRGB), let b = b.usingColorSpace(.sRGB) else { return false }
        return abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02
            && abs(a.blueComponent - b.blueComponent) < 0.02
    }

    private static func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
        abs(a.x - b.x) < 1.5 && abs(a.y - b.y) < 1.5
    }

    private static func event(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        )
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("forme.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 600)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fail("No PDF context") }
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Shape editing smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
