import AppKit
import PDFKit

@main
struct FormOverlaySmoke {
    @MainActor
    static func main() {
        let suiteName = "it.lucalazzaroni.zzpdf.tests.forms.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let preferences = AppPreferences(defaults: defaults)
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
        let workspace = PDFWorkspace(preferences: preferences)
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

        let originalFormFont = textWidget.font
        let longFormValue = "This value is deliberately longer than the available form field width"
        textField.stringValue = longFormValue
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        guard textField.fittedPDFPointSize < textField.maximumPDFPointSize else {
            fatalError("Long form text was not automatically reduced to fit the field.")
        }
        textField.stringValue = "Short value"
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        guard abs(textField.fittedPDFPointSize - textField.maximumPDFPointSize) < 0.01,
              abs((textField.font?.pointSize ?? 0) - textField.maximumPDFPointSize) < 0.01 else {
            fatalError("Form text did not return to its normal size after shortening.")
        }
        textField.stringValue = longFormValue
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        let fittedFormSize = textField.fittedPDFPointSize
        overlay.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: textField))
        guard textWidget.widgetStringValue == longFormValue,
              abs((textWidget.font?.pointSize ?? 0) - fittedFormSize) < 0.01 else {
            fatalError(
                "The fitted form text size was not saved to the PDF annotation " +
                "(expected \(fittedFormSize), got \(textWidget.font?.pointSize ?? 0))."
            )
        }
        let renderedWidth = (longFormValue as NSString).size(withAttributes: [.font: textWidget.font!]).width
        guard renderedWidth <= textWidget.bounds.width - 8 + 0.5 else {
            fatalError("Automatically reduced form text still exceeded the PDF field width.")
        }
        workspace.undo()
        guard textWidget.widgetStringValue == "",
              textWidget.font?.fontName == originalFormFont?.fontName,
              abs((textWidget.font?.pointSize ?? 0) - (originalFormFont?.pointSize ?? 0)) < 0.01 else {
            fatalError("Undo did not restore the original form text appearance.")
        }
        workspace.redo()
        guard textWidget.widgetStringValue == longFormValue,
              abs((textWidget.font?.pointSize ?? 0) - fittedFormSize) < 0.01 else {
            fatalError("Redo did not restore the fitted form text appearance.")
        }
        preferences.autoFitFormText = false
        textField.stringValue = longFormValue
        overlay.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: textField))
        guard abs(textField.fittedPDFPointSize - textField.maximumPDFPointSize) < 0.01 else {
            fatalError("The form auto-fit preference could not be disabled.")
        }
        preferences.autoFitFormText = true

        workspace.activeTool = .select
        overlay.refresh()
        guard textField.isHidden, checkButton.isHidden else {
            fatalError("PDF form controls should only be visible in Fill Forms mode.")
        }

        workspace.activeTool = .text
        workspace.textToInsert = "Text"
        workspace.textFontSize = 22
        workspace.addAnnotation(at: CGPoint(x: 80, y: 520), on: page)
        guard workspace.showFreeTextEditor,
              workspace.freeTextDraftText.isEmpty,
              let addedText = workspace.selectedAnnotation,
              addedText.isSubtype(.freeText),
              addedText.contents == "Text",
              abs((addedText.font?.pointSize ?? 0) - 22) < 0.01 else {
            fatalError("Added free text did not open in the editor.")
        }
        workspace.freeTextDraftText = "Editable text"
        workspace.freeTextDraftFontSize = 28
        workspace.commitFreeTextEditing()
        guard !workspace.showFreeTextEditor,
              addedText.contents == "Editable text",
              abs((addedText.font?.pointSize ?? 0) - 28) < 0.01 else {
            fatalError("Added free text was not saved from the editor.")
        }

        workspace.beginSelectedTextSizeChange()
        workspace.previewSelectedTextFontSize(34)
        workspace.endSelectedTextSizeChange()
        guard abs((addedText.font?.pointSize ?? 0) - 34) < 0.01 else {
            fatalError("Selected free text size was not editable.")
        }
        workspace.undo()
        guard abs((addedText.font?.pointSize ?? 0) - 28) < 0.01,
              abs(workspace.selectedTextFontSize - 28) < 0.01 else {
            fatalError("Undo did not synchronize the selected text size control.")
        }
        workspace.redo()
        guard abs((addedText.font?.pointSize ?? 0) - 34) < 0.01,
              abs(workspace.selectedTextFontSize - 34) < 0.01 else {
            fatalError("Redo did not synchronize the selected text size control.")
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

        workspace.undo()
        guard shape.interiorColor == nil, !workspace.selectedShapeHasFill else {
            fatalError("Undo did not synchronize the selected shape fill controls.")
        }
        workspace.undo()
        guard abs((shape.border?.lineWidth ?? 0) - 2.5) < 0.01,
              abs(workspace.selectedShapeStrokeWidth - 2.5) < 0.01 else {
            fatalError("Undo did not synchronize the selected shape stroke controls.")
        }
        workspace.redo()
        workspace.redo()
        guard workspace.selectedShapeHasFill,
              abs(workspace.selectedShapeStrokeWidth - 7) < 0.01 else {
            fatalError("Redo did not synchronize the selected shape controls.")
        }

        workspace.activateTool(.fillForms)
        overlay.refresh()
        guard workspace.selectedAnnotation == nil,
              workspace.activeTool == .fillForms,
              !textField.isHidden,
              !checkButton.isHidden else {
            fatalError("Fill Forms did not clear the previous annotation selection.")
        }

        workspace.activateTool(.text)
        workspace.addAnnotation(at: CGPoint(x: 595, y: 300), on: page)
        guard let edgeText = workspace.selectedAnnotation,
              edgeText.bounds.maxX <= page.bounds(for: .cropBox).maxX,
              edgeText.bounds.minX >= page.bounds(for: .cropBox).minX else {
            fatalError("Free text was allowed to extend beyond the page bounds.")
        }
        workspace.cancelFreeTextEditing()

        workspace.selectAnnotation(addedText)
        workspace.beginEditingFreeText(addedText)
        workspace.statusMessage = "Previous status"
        workspace.cancelFreeTextEditing()
        guard addedText.page === page, workspace.statusMessage == "Text editing cancelled" else {
            fatalError("Cancelling existing free text produced an incorrect state or status.")
        }

        let searchRequest = workspace.searchFocusRequest
        workspace.focusSearch()
        guard workspace.searchFocusRequest == searchRequest + 1 else {
            fatalError("The Find command did not request search focus.")
        }

        print("Form, free-text, and shape appearance smoke test passed.")
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
