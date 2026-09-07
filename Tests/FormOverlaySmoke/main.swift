import AppKit
import PDFKit

@main
struct FormOverlaySmoke {
    @MainActor
    static func main() {
        let pageImage = NSImage(size: NSSize(width: 600, height: 800))
        pageImage.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 0, width: 600, height: 800)).fill()
        pageImage.unlockFocus()
        let page = PDFPage(image: pageImage)!

        let textWidget = PDFAnnotation(
            bounds: CGRect(x: 60, y: 650, width: 240, height: 32),
            forType: .widget,
            withProperties: nil
        )
        textWidget.widgetFieldType = .text
        textWidget.widgetStringValue = ""
        page.addAnnotation(textWidget)

        let checkWidget = PDFAnnotation(
            bounds: CGRect(x: 60, y: 590, width: 24, height: 24),
            forType: .widget,
            withProperties: nil
        )
        checkWidget.widgetFieldType = .button
        checkWidget.widgetControlType = PDFWidgetControlType(rawValue: 2)!
        page.addAnnotation(checkWidget)
        let document = PDFDocument()
        document.insert(page, at: 0)
        let workspace = PDFWorkspace()
        let pdfView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 650, height: 850))
        workspace.pdfDocument = document
        workspace.pdfView = pdfView
        workspace.activeTool = .fillForms
        pdfView.workspace = workspace
        pdfView.document = document
        pdfView.layoutDocumentView()

        let overlay = PDFPageFormOverlay(owner: pdfView, page: page)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        overlay.refresh()
        overlay.layoutSubtreeIfNeeded()

        guard let textField = overlay.subviews.compactMap({ $0 as? PDFOverlayTextField }).first,
              let checkButton = overlay.subviews.compactMap({ $0 as? PDFOverlayButton }).first,
              !textField.isHidden,
              textField.isEditable,
              textField.isEnabled,
              !checkButton.isHidden,
              checkButton.isEnabled,
              overlay.hitTest(textField.frame.center) === textField else {
            fatalError("PDF form overlay controls are not visible and interactive.")
        }

        workspace.activeTool = .select
        overlay.refresh()
        guard textField.isHidden, checkButton.isHidden else {
            fatalError("PDF form controls should only be visible in Fill Forms mode.")
        }

        workspace.activeTool = .text
        workspace.textToInsert = "Text"
        workspace.addAnnotation(at: CGPoint(x: 80, y: 520), on: page)
        guard workspace.showFreeTextEditor,
              workspace.freeTextDraftText.isEmpty,
              let addedText = workspace.selectedAnnotation,
              addedText.isSubtype(.freeText),
              addedText.contents == "Text" else {
            fatalError("Added free text did not open in the editor.")
        }
        workspace.freeTextDraftText = "Editable text"
        workspace.commitFreeTextEditing()
        guard !workspace.showFreeTextEditor, addedText.contents == "Editable text" else {
            fatalError("Added free text was not saved from the editor.")
        }

        workspace.activeTool = .rectangle
        workspace.shapeHasFill = false
        workspace.lineWidth = 2.5
        workspace.addAnnotation(
            at: CGPoint(x: 80, y: 450),
            on: page,
            dragPoints: [CGPoint(x: 80, y: 450), CGPoint(x: 260, y: 350)]
        )
        guard let shape = workspace.selectedAnnotation,
              shape.isSubtype(.square),
              shape.interiorColor == nil,
              abs((shape.border?.lineWidth ?? 0) - 2.5) < 0.01 else {
            fatalError("A new shape did not preserve the default transparent fill and stroke width.")
        }
        workspace.beginSelectedShapeStrokeChange()
        workspace.previewSelectedShapeStrokeWidth(7)
        workspace.endSelectedShapeStrokeChange()
        workspace.setSelectedShapeFillEnabled(true)
        guard abs((shape.border?.lineWidth ?? 0) - 7) < 0.01,
              shape.interiorColor != nil else {
            fatalError("Selected shape appearance was not editable.")
        }

        print("Form, free-text, and shape appearance smoke test passed.")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
