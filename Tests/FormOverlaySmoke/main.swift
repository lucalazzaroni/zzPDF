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
        pdfView.workspace = workspace
        pdfView.document = document
        pdfView.layoutDocumentView()

        let overlay = PDFPageFormOverlay(owner: pdfView, page: page)
        overlay.frame = pdfView.bounds
        pdfView.addSubview(overlay)
        overlay.refresh()
        overlay.layoutSubtreeIfNeeded()

        let addedText = PDFAnnotation(
            bounds: CGRect(x: 60, y: 520, width: 240, height: 32),
            forType: .freeText,
            withProperties: nil
        )
        addedText.contents = "Text"
        page.addAnnotation(addedText)
        overlay.beginEditing(addedText)
        overlay.layoutSubtreeIfNeeded()

        guard let textField = overlay.subviews.compactMap({ $0 as? PDFOverlayTextField }).first,
              let addedTextEditor = overlay.subviews.compactMap({ $0 as? PDFOverlayTextField }).first(where: { $0.isFreeTextEditor }),
              let checkButton = overlay.subviews.compactMap({ $0 as? PDFOverlayButton }).first,
              !textField.isHidden,
              textField.isEditable,
              textField.isEnabled,
              addedTextEditor.isEditable,
              addedTextEditor.isSelectable,
              !checkButton.isHidden,
              checkButton.isEnabled,
              overlay.hitTest(textField.frame.center) === textField else {
            fatalError("PDF form overlay controls are not visible and interactive.")
        }

        print("Form overlay smoke test passed.")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
