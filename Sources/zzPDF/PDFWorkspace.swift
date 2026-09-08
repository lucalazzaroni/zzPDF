import AppKit
import PDFKit
import SwiftUI
@preconcurrency import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, fillForms, highlight, underline, strikeOut, note, text, draw, rectangle, oval, redact, signature

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: "Select"
        case .fillForms: "Fill Forms"
        case .highlight: "Highlight"
        case .underline: "Underline"
        case .strikeOut: "Strike Through"
        case .note: "Note"
        case .text: "Text"
        case .draw: "Draw"
        case .rectangle: "Rectangle"
        case .oval: "Ellipse"
        case .redact: "Redact"
        case .signature: "Signature"
        }
    }
    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .fillForms: "list.bullet.rectangle"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeOut: "strikethrough"
        case .note: "note.text"
        case .text: "textformat"
        case .draw: "pencil.tip"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .redact: "eye.slash"
        case .signature: "signature"
        }
    }

    var markupKind: MarkupKind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeOut: .strikeOut
        default: nil
        }
    }
}

enum MarkupKind { case highlight, underline, strikeOut }

enum PageLayoutMode: String, CaseIterable, Identifiable {
    case single, continuous, facing, facingContinuous

    var id: String { rawValue }
    var label: String {
        switch self {
        case .single: "Single Page"
        case .continuous: "Continuous Scroll"
        case .facing: "Two Pages"
        case .facingContinuous: "Two Pages Continuous"
        }
    }
    var symbol: String {
        switch self {
        case .single: "rectangle.portrait"
        case .continuous: "rectangle.portrait.on.rectangle.portrait"
        case .facing: "rectangle.split.2x1"
        case .facingContinuous: "rectangle.split.2x1.fill"
        }
    }
    var pdfMode: PDFDisplayMode {
        switch self {
        case .single: .singlePage
        case .continuous: .singlePageContinuous
        case .facing: .twoUp
        case .facingContinuous: .twoUpContinuous
        }
    }
}

private struct PDFEditAction {
    let undo: () -> Void
    let redo: () -> Void
    let wasDirtyBefore: Bool
}

@MainActor
final class PDFWorkspace: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var hasTextSelection = false
    @Published var activeTool: CanvasTool = .select
    @Published var pageLayout: PageLayoutMode = .continuous
    @Published var annotationColor: Color = .black
    @Published var lineWidth: Double = 2.5
    @Published var shapeHasFill = false
    @Published var shapeFillColor: Color = .black
    @Published var selectedShapeStrokeWidth: Double = 2.5
    @Published var selectedShapeHasFill = false
    @Published var selectedShapeFillColor: Color = .black
    @Published var textToInsert = "Text"
    @Published var textFontSize: Double = 15
    @Published var selectedTextFontSize: Double = 15
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var searchFocusRequest = 0
    @Published var sidebarVisible = true
    @Published var inspectorVisible = true
    @Published var showSignaturePad = false
    @Published var showPasswordExport = false
    @Published var showOCRResult = false
    @Published var showNoteEditor = false
    @Published var showFreeTextEditor = false
    @Published var ocrText = ""
    @Published var annotationDraftText = ""
    @Published var freeTextDraftText = ""
    @Published var freeTextDraftFontSize: Double = 15
    @Published var statusMessage = "Open a PDF to get started"
    @Published var isDirty = false
    @Published var savedSignature: [[CGPoint]] = []
    @Published var signatureImage: NSImage?

    private var undoActions: [PDFEditAction] = []
    private var redoActions: [PDFEditAction] = []
    private var noteOriginalText: String?
    private var pendingNewNote: PDFAnnotation?
    private var pendingNoteWasDirty = false
    private var pendingNewFreeText: PDFAnnotation?
    private var pendingFreeTextWasDirty = false
    private var editingFreeText: PDFAnnotation?
    private var shapeStrokeBeforeEditing: Double?
    private var shapeStrokeWasDirty = false
    private var textSizeBeforeEditing: Double?
    private var textSizeWasDirty = false

    weak var pdfView: InteractivePDFView?

    var hasDocument: Bool { pdfDocument != nil }
    var pageCount: Int { pdfDocument?.pageCount ?? 0 }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var nsAnnotationColor: NSColor { NSColor(annotationColor) }
    var hasSignature: Bool { !savedSignature.isEmpty || signatureImage != nil }
    var selectedAnnotationIsShape: Bool {
        guard let annotation = selectedAnnotation else { return false }
        if annotation.contents == "Redaction — export a flattened copy" { return false }
        return annotation.isSubtype(.square) || annotation.isSubtype(.circle)
    }
    var selectedAnnotationIsFreeText: Bool {
        selectedAnnotation?.isSubtype(.freeText) == true
    }
    var canUndo: Bool { !undoActions.isEmpty || pdfView?.undoManager?.canUndo == true }
    var canRedo: Bool { !redoActions.isEmpty || pdfView?.undoManager?.canRedo == true }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let document = PDFDocument(url: url) else {
            presentError("The document could not be opened.")
            return
        }
        if document.isLocked {
            let password = requestPassword(title: "Protected PDF", message: "Enter the password to open this document.")
            guard let password, document.unlock(withPassword: password) else {
                presentError("Invalid password.")
                return
            }
        }
        pdfDocument = document
        fileURL = url
        currentPageIndex = 0
        selectedAnnotation = nil
        hasTextSelection = false
        pendingNewNote = nil
        pendingNewFreeText = nil
        undoActions.removeAll()
        redoActions.removeAll()
        isDirty = false
        searchResults = []
        statusMessage = "\(document.pageCount) pages"
    }

    func save() {
        guard let document = pdfDocument else { return }
        guard let url = fileURL else { saveAs(); return }
        if document.write(to: url) {
            isDirty = false
            statusMessage = "Saved"
        } else {
            presentError("The document could not be saved.")
        }
    }

    func saveAs() {
        guard let document = pdfDocument, let url = chooseSaveURL(defaultName: "\(displayName).pdf") else { return }
        if document.write(to: url) {
            fileURL = url
            isDirty = false
            statusMessage = "Copy saved"
        } else {
            presentError("The document could not be saved.")
        }
    }

    func exportFlattened() {
        guard let document = pdfDocument,
              let url = chooseSaveURL(defaultName: "\(displayName)-flattened.pdf") else { return }
        let options: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true
        ]
        if document.write(to: url, withOptions: options) {
            statusMessage = "Flattened copy exported"
        } else {
            presentError("The export failed.")
        }
    }

    func exportProtected(ownerPassword: String, userPassword: String, flatten: Bool) {
        guard let document = pdfDocument,
              !ownerPassword.isEmpty,
              let url = chooseSaveURL(defaultName: "\(displayName)-protected.pdf") else { return }
        var options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: ownerPassword]
        if !userPassword.isEmpty { options[.userPasswordOption] = userPassword }
        if flatten { options[.burnInAnnotationsOption] = true }
        if document.write(to: url, withOptions: options) {
            statusMessage = "Protected PDF exported"
            showPasswordExport = false
        } else {
            presentError("The PDF could not be protected.")
        }
    }

    func mergePDF() {
        guard let document = pdfDocument else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "Documents will be inserted after the current page"
        guard panel.runModal() == .OK else { return }
        let wasDirty = isDirty
        var insertionIndex = min(currentPageIndex + 1, document.pageCount)
        var inserted: [(PDFPage, Int)] = []
        for url in panel.urls {
            guard let extra = PDFDocument(url: url), !extra.isLocked else { continue }
            for index in 0..<extra.pageCount {
                if let page = extra.page(at: index)?.copy() as? PDFPage {
                    document.insert(page, at: insertionIndex)
                    inserted.append((page, insertionIndex))
                    insertionIndex += 1
                }
            }
        }
        guard !inserted.isEmpty else { return }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            for (page, _) in inserted.reversed() { removePage(page, from: document) }
        }, redo: {
            for (page, index) in inserted { document.insert(page, at: min(index, document.pageCount)) }
        })
        changed("PDFs merged")
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = true
        panel.message = "Each image will become a page"
        guard panel.runModal() == .OK else { return }
        let wasDirty = isDirty
        let hadDocument = pdfDocument != nil
        let destination = pdfDocument ?? PDFDocument()
        var inserted: [(PDFPage, Int)] = []
        for url in panel.urls {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                let index = destination.pageCount
                destination.insert(page, at: index)
                inserted.append((page, index))
            }
        }
        if destination.pageCount > 0 {
            pdfDocument = destination
            fileURL = nil
            registerEdit(wasDirtyBefore: wasDirty, undo: { [weak self] in
                for (page, _) in inserted.reversed() { removePage(page, from: destination) }
                if !hadDocument { self?.pdfDocument = nil }
            }, redo: { [weak self] in
                if !hadDocument { self?.pdfDocument = destination }
                for (page, index) in inserted where destination.index(for: page) == NSNotFound {
                    destination.insert(page, at: min(index, destination.pageCount))
                }
            })
            changed("Images imported")
        }
    }

    func extractCurrentPage() {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex)?.copy() as? PDFPage,
              let url = chooseSaveURL(defaultName: "Page-\(currentPageIndex + 1).pdf") else { return }
        let output = PDFDocument()
        output.insert(page, at: 0)
        if output.write(to: url) { statusMessage = "Page extracted" }
    }

    func selectPage(_ index: Int) {
        guard let document = pdfDocument, index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        currentPageIndex = index
        pdfView?.go(to: page)
    }

    func moveCurrentPage(by offset: Int) {
        guard let document = pdfDocument else { return }
        let target = currentPageIndex + offset
        guard target >= 0, target < document.pageCount,
              let page = document.page(at: currentPageIndex) else { return }
        let wasDirty = isDirty
        let original = currentPageIndex
        document.removePage(at: currentPageIndex)
        document.insert(page, at: target)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            movePage(page, in: document, to: original)
        }, redo: {
            movePage(page, in: document, to: target)
        })
        currentPageIndex = target
        changed("Page moved")
        selectPage(target)
    }

    func duplicateCurrentPage() {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex)?.copy() as? PDFPage else { return }
        let wasDirty = isDirty
        let index = currentPageIndex + 1
        document.insert(page, at: index)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            removePage(page, from: document)
        }, redo: {
            document.insert(page, at: min(index, document.pageCount))
        })
        changed("Page duplicated")
        selectPage(currentPageIndex + 1)
    }

    func deleteCurrentPage() {
        guard let document = pdfDocument, document.pageCount > 0 else { return }
        guard let page = document.page(at: currentPageIndex) else { return }
        let wasDirty = isDirty
        let index = currentPageIndex
        document.removePage(at: index)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            document.insert(page, at: min(index, document.pageCount))
        }, redo: {
            removePage(page, from: document)
        })
        currentPageIndex = max(0, min(currentPageIndex, document.pageCount - 1))
        changed("Page deleted")
        if document.pageCount > 0 { selectPage(currentPageIndex) }
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        let wasDirty = isDirty
        let oldRotation = page.rotation
        let newRotation = (oldRotation + degrees + 360) % 360
        page.rotation = newRotation
        registerEdit(wasDirtyBefore: wasDirty, undo: { page.rotation = oldRotation }, redo: { page.rotation = newRotation })
        changed("Page rotated")
    }

    func addMarkup(_ kind: MarkupKind) {
        guard let selection = pdfView?.currentSelection else {
            statusMessage = "Select text in the document first"
            return
        }
        let wasDirty = isDirty
        var additions: [(PDFPage, PDFAnnotation)] = []
        for page in selection.pages {
            let bounds = selection.bounds(for: page)
            guard !bounds.isEmpty else { continue }
            let subtype: PDFAnnotationSubtype
            switch kind {
            case .highlight: subtype = .highlight
            case .underline: subtype = .underline
            case .strikeOut: subtype = .strikeOut
            }
            let annotation = PDFAnnotation(bounds: bounds, forType: subtype, withProperties: nil)
            annotation.color = kind == .highlight ? NSColor.systemYellow.withAlphaComponent(0.45) : nsAnnotationColor
            page.addAnnotation(annotation)
            additions.append((page, annotation))
        }
        guard !additions.isEmpty else { return }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            for (page, annotation) in additions { page.removeAnnotation(annotation) }
        }, redo: {
            for (page, annotation) in additions { page.addAnnotation(annotation) }
        })
        pdfView?.clearSelection()
        hasTextSelection = false
        changed("Annotation added")
    }

    func addAnnotation(at point: CGPoint, on page: PDFPage, dragPoints: [CGPoint] = []) {
        let color = nsAnnotationColor
        let annotation: PDFAnnotation?
        let tool = activeTool
        switch tool {
        case .select, .fillForms, .highlight, .underline, .strikeOut:
            return
        case .note:
            let item = NoteMarkerAnnotation(bounds: CGRect(x: point.x - 14, y: point.y - 14, width: 28, height: 28))
            item.contents = ""
            annotation = item
        case .text:
            let item = PDFAnnotation(
                bounds: clampedTextBounds(at: point, on: page),
                forType: .freeText,
                withProperties: nil
            )
            item.contents = textToInsert
            item.font = .systemFont(ofSize: textFontSize)
            item.fontColor = color
            item.color = .clear
            annotation = item
        case .rectangle, .oval:
            let rect = normalizedBounds(from: dragPoints, fallback: point, size: CGSize(width: 130, height: 80))
            let item = PDFAnnotation(bounds: rect, forType: tool == .rectangle ? .square : .circle, withProperties: nil)
            item.color = color
            item.interiorColor = shapeHasFill ? NSColor(shapeFillColor) : nil
            let border = PDFBorder()
            border.lineWidth = lineWidth
            item.border = border
            annotation = item
        case .redact:
            let rect = normalizedBounds(from: dragPoints, fallback: point, size: CGSize(width: 150, height: 30))
            let item = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
            item.color = .black
            item.interiorColor = .black
            item.contents = "Redaction — export a flattened copy"
            let border = PDFBorder()
            border.lineWidth = 0
            item.border = border
            annotation = item
        case .draw:
            annotation = makeInkAnnotation(points: dragPoints, color: color, width: lineWidth)
        case .signature:
            guard hasSignature else {
                showSignaturePad = true
                return
            }
            annotation = makeSignatureAnnotation(at: point, color: color)
        }
        if let annotation {
            let wasDirty = isDirty
            page.addAnnotation(annotation)
            selectAnnotation(annotation)
            changed("Annotation added")
            if tool == .note {
                pendingNewNote = annotation
                pendingNoteWasDirty = wasDirty
                annotationDraftText = ""
                noteOriginalText = ""
                showNoteEditor = true
            } else if tool == .text {
                pendingNewFreeText = annotation
                pendingFreeTextWasDirty = wasDirty
                beginEditingFreeText(annotation)
            } else {
                registerEdit(wasDirtyBefore: wasDirty, undo: {
                    page.removeAnnotation(annotation)
                }, redo: {
                    page.addAnnotation(annotation)
                })
            }
        }
    }

    private func normalizedBounds(from points: [CGPoint], fallback: CGPoint, size: CGSize) -> CGRect {
        guard let first = points.first, let last = points.last,
              abs(last.x - first.x) > 4, abs(last.y - first.y) > 4 else {
            return CGRect(x: fallback.x, y: fallback.y - size.height, width: size.width, height: size.height)
        }
        return CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                      width: abs(last.x - first.x), height: abs(last.y - first.y))
    }

    private func clampedTextBounds(at point: CGPoint, on page: PDFPage) -> CGRect {
        let pageBounds = page.bounds(for: .cropBox)
        let size = CGSize(width: min(210, pageBounds.width), height: min(34, pageBounds.height))
        let maximumX = max(pageBounds.minX, pageBounds.maxX - size.width)
        let maximumY = max(pageBounds.minY, pageBounds.maxY - size.height)
        let origin = CGPoint(
            x: min(max(point.x, pageBounds.minX), maximumX),
            y: min(max(point.y - 20, pageBounds.minY), maximumY)
        )
        return CGRect(origin: origin, size: size)
    }

    private func makeInkAnnotation(points: [CGPoint], color: NSColor, width: Double) -> PDFAnnotation? {
        guard points.count > 1 else { return nil }
        let minX = points.map(\.x).min() ?? 0
        let maxX = points.map(\.x).max() ?? 0
        let minY = points.map(\.y).min() ?? 0
        let maxY = points.map(\.y).max() ?? 0
        let padding = width + 2
        let bounds = CGRect(x: minX - padding, y: minY - padding,
                            width: max(maxX - minX + padding * 2, 4),
                            height: max(maxY - minY + padding * 2, 4))
        return ScalableInkAnnotation(
            bounds: bounds,
            pageStrokes: [points],
            color: color,
            lineWidth: width
        )
    }

    func signatureBounds(at point: CGPoint) -> CGRect {
        let maximum = CGSize(width: 180, height: 90)
        if let image = signatureImage, image.size.width > 0, image.size.height > 0 {
            let scale = min(maximum.width / image.size.width, maximum.height / image.size.height)
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            return CGRect(x: point.x, y: point.y - size.height, width: size.width, height: size.height)
        }
        return CGRect(x: point.x, y: point.y - 70, width: 180, height: 70)
    }

    private func makeSignatureAnnotation(at point: CGPoint, color: NSColor) -> PDFAnnotation? {
        let bounds = signatureBounds(at: point)
        if let signatureImage {
            return ImageStampAnnotation(bounds: bounds, image: signatureImage)
        }
        let item = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        item.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        item.border = border
        for stroke in savedSignature where stroke.count > 1 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x * bounds.width, y: (1 - stroke[0].y) * bounds.height))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x * bounds.width, y: (1 - point.y) * bounds.height))
            }
            item.add(path)
        }
        return item
    }

    func removeSelectedAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }
        let wasDirty = isDirty
        page.removeAnnotation(annotation)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            page.addAnnotation(annotation)
        }, redo: {
            page.removeAnnotation(annotation)
        })
        selectAnnotation(nil)
        changed("Annotation removed")
    }

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        if annotation != nil {
            pdfView?.clearSelection()
            hasTextSelection = false
        }
        selectedAnnotation = annotation
        synchronizeSelectedShapeAppearance()
        synchronizeSelectedTextAppearance()
        pdfView?.refreshInteractionAppearance()
    }

    private func synchronizeSelectedShapeAppearance() {
        guard selectedAnnotationIsShape, let annotation = selectedAnnotation else { return }
        selectedShapeStrokeWidth = Double(annotation.border?.lineWidth ?? 1)
        if let fill = annotation.interiorColor {
            selectedShapeHasFill = true
            selectedShapeFillColor = Color(nsColor: fill)
        } else {
            selectedShapeHasFill = false
        }
    }

    private func synchronizeSelectedTextAppearance() {
        guard selectedAnnotationIsFreeText, let annotation = selectedAnnotation else { return }
        selectedTextFontSize = Double(annotation.font?.pointSize ?? 15)
    }

    func beginSelectedTextSizeChange() {
        guard selectedAnnotationIsFreeText, let annotation = selectedAnnotation else { return }
        textSizeBeforeEditing = Double(annotation.font?.pointSize ?? 15)
        textSizeWasDirty = isDirty
    }

    func previewSelectedTextFontSize(_ size: Double) {
        guard selectedAnnotationIsFreeText, let annotation = selectedAnnotation else { return }
        applyFontSize(size, to: annotation)
        selectedTextFontSize = size
        isDirty = true
        pdfView?.needsDisplay = true
        pdfView?.refreshInteractionAppearance()
    }

    func endSelectedTextSizeChange() {
        guard let annotation = selectedAnnotation,
              annotation.isSubtype(.freeText),
              let oldSize = textSizeBeforeEditing else { return }
        let newSize = selectedTextFontSize
        textSizeBeforeEditing = nil
        guard oldSize != newSize else {
            isDirty = textSizeWasDirty
            return
        }
        let wasDirty = textSizeWasDirty
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { self.applyFontSize(oldSize, to: annotation) },
            redo: { self.applyFontSize(newSize, to: annotation) }
        )
        changed("Text size updated")
    }

    private func applyFontSize(_ size: Double, to annotation: PDFAnnotation) {
        let currentFont = annotation.font ?? .systemFont(ofSize: size)
        if currentFont.fontName.hasPrefix(".") {
            annotation.font = .systemFont(ofSize: size)
        } else {
            annotation.font = NSFontManager.shared.convert(currentFont, toSize: size)
        }
    }

    func beginSelectedShapeStrokeChange() {
        guard selectedAnnotationIsShape, let annotation = selectedAnnotation else { return }
        shapeStrokeBeforeEditing = Double(annotation.border?.lineWidth ?? 1)
        shapeStrokeWasDirty = isDirty
    }

    func previewSelectedShapeStrokeWidth(_ width: Double) {
        guard selectedAnnotationIsShape, let annotation = selectedAnnotation else { return }
        applyStrokeWidth(width, to: annotation)
        selectedShapeStrokeWidth = width
        isDirty = true
        pdfView?.needsDisplay = true
    }

    func endSelectedShapeStrokeChange() {
        guard let annotation = selectedAnnotation,
              let oldWidth = shapeStrokeBeforeEditing else { return }
        let newWidth = selectedShapeStrokeWidth
        shapeStrokeBeforeEditing = nil
        guard oldWidth != newWidth else {
            isDirty = shapeStrokeWasDirty
            return
        }
        let wasDirty = shapeStrokeWasDirty
        registerEdit(wasDirtyBefore: wasDirty, undo: { self.applyStrokeWidth(oldWidth, to: annotation) }, redo: { self.applyStrokeWidth(newWidth, to: annotation) })
        changed("Shape stroke updated")
    }

    func setSelectedShapeFillEnabled(_ enabled: Bool) {
        guard selectedAnnotationIsShape, let annotation = selectedAnnotation else { return }
        let oldFill = annotation.interiorColor
        let newFill = enabled ? NSColor(selectedShapeFillColor) : nil
        guard oldFill != newFill else { return }
        let wasDirty = isDirty
        annotation.interiorColor = newFill
        selectedShapeHasFill = enabled
        registerEdit(wasDirtyBefore: wasDirty, undo: { annotation.interiorColor = oldFill }, redo: { annotation.interiorColor = newFill })
        changed("Shape fill updated")
    }

    func setSelectedShapeFillColor(_ color: Color) {
        selectedShapeFillColor = color
        guard selectedAnnotationIsShape, selectedShapeHasFill, let annotation = selectedAnnotation else { return }
        let oldFill = annotation.interiorColor
        let newFill = NSColor(color)
        guard oldFill != newFill else { return }
        let wasDirty = isDirty
        annotation.interiorColor = newFill
        registerEdit(wasDirtyBefore: wasDirty, undo: { annotation.interiorColor = oldFill }, redo: { annotation.interiorColor = newFill })
        changed("Shape fill color updated")
    }

    private func applyStrokeWidth(_ width: Double, to annotation: PDFAnnotation) {
        let border = annotation.border ?? PDFBorder()
        border.lineWidth = width
        annotation.border = border
        pdfView?.needsDisplay = true
    }

    func beginEditingSelectedNote() {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.text) else { return }
        annotationDraftText = annotation.contents ?? ""
        noteOriginalText = annotationDraftText
        showNoteEditor = true
    }

    func commitSelectedNote() {
        guard let annotation = selectedAnnotation else { showNoteEditor = false; return }
        let oldText = noteOriginalText ?? annotation.contents ?? ""
        let newText = annotationDraftText
        if pendingNewNote === annotation, let page = annotation.page {
            annotation.contents = newText
            let wasDirty = pendingNoteWasDirty
            registerEdit(wasDirtyBefore: wasDirty, undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) })
            pendingNewNote = nil
            changed("Note added")
        } else if oldText != newText {
            let wasDirty = isDirty
            annotation.contents = newText
            registerEdit(wasDirtyBefore: wasDirty, undo: { annotation.contents = oldText }, redo: { annotation.contents = newText })
            changed("Note updated")
        }
        noteOriginalText = nil
        showNoteEditor = false
        if activeTool == .note { statusMessage = "Note saved — click to add another" }
    }

    func cancelNoteEditing() {
        if let annotation = pendingNewNote {
            annotation.page?.removeAnnotation(annotation)
            pendingNewNote = nil
            selectedAnnotation = nil
            isDirty = pendingNoteWasDirty
            activeTool = .select
            statusMessage = "Unsaved note removed"
            pdfView?.refreshInteractionAppearance()
        }
        noteOriginalText = nil
        showNoteEditor = false
        objectWillChange.send()
    }

    func updateEditableText(in annotation: PDFAnnotation, to value: String) {
        let isWidget = annotation.isSubtype(.widget)
        let oldValue = isWidget ? (annotation.widgetStringValue ?? "") : (annotation.contents ?? "")
        let apply: (String) -> Void = { text in
            if isWidget { annotation.widgetStringValue = text } else { annotation.contents = text }
        }
        if pendingNewFreeText === annotation, let page = annotation.page {
            apply(value)
            let wasDirty = pendingFreeTextWasDirty
            registerEdit(wasDirtyBefore: wasDirty, undo: { page.removeAnnotation(annotation) }, redo: { page.addAnnotation(annotation) })
            pendingNewFreeText = nil
            changed("Text added")
            return
        }
        guard oldValue != value else { return }
        let wasDirty = isDirty
        apply(value)
        registerEdit(wasDirtyBefore: wasDirty, undo: { apply(oldValue) }, redo: { apply(value) })
        changed(isWidget ? "Form field updated" : "Text updated")
    }

    func beginEditingFreeText(_ annotation: PDFAnnotation) {
        guard annotation.isSubtype(.freeText) else { return }
        editingFreeText = annotation
        freeTextDraftText = pendingNewFreeText === annotation ? "" : (annotation.contents ?? "")
        freeTextDraftFontSize = Double(annotation.font?.pointSize ?? 15)
        showFreeTextEditor = true
    }

    func commitFreeTextEditing() {
        guard let annotation = editingFreeText else {
            showFreeTextEditor = false
            return
        }
        commitFreeText(annotation, text: freeTextDraftText, fontSize: freeTextDraftFontSize)
        editingFreeText = nil
        showFreeTextEditor = false
        if activeTool == .text { statusMessage = "Text saved — click to add another" }
    }

    private func commitFreeText(_ annotation: PDFAnnotation, text: String, fontSize: Double) {
        let oldText = annotation.contents ?? ""
        let oldFontSize = Double(annotation.font?.pointSize ?? 15)
        let apply: (String, Double) -> Void = { newText, newFontSize in
            annotation.contents = newText
            self.applyFontSize(newFontSize, to: annotation)
        }
        if pendingNewFreeText === annotation, let page = annotation.page {
            apply(text, fontSize)
            selectedTextFontSize = fontSize
            let wasDirty = pendingFreeTextWasDirty
            registerEdit(
                wasDirtyBefore: wasDirty,
                undo: { page.removeAnnotation(annotation) },
                redo: { page.addAnnotation(annotation) }
            )
            pendingNewFreeText = nil
            changed("Text added")
            return
        }
        guard oldText != text || oldFontSize != fontSize else { return }
        let wasDirty = isDirty
        apply(text, fontSize)
        selectedTextFontSize = fontSize
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { apply(oldText, oldFontSize) },
            redo: { apply(text, fontSize) }
        )
        changed("Text updated")
    }

    func cancelFreeTextEditing() {
        let annotation = editingFreeText
        editingFreeText = nil
        showFreeTextEditor = false
        if let annotation, pendingNewFreeText === annotation {
            cancelEditableText(annotation)
        } else if annotation != nil {
            statusMessage = "Text editing cancelled"
        }
    }

    func updateButtonField(_ annotation: PDFAnnotation, to state: PDFWidgetCellState) {
        let oldState = annotation.buttonWidgetState
        guard oldState != state else { return }
        let wasDirty = isDirty
        annotation.buttonWidgetState = state
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { annotation.buttonWidgetState = oldState },
            redo: { annotation.buttonWidgetState = state }
        )
        changed("Form control updated")
    }

    func cancelEditableText(_ annotation: PDFAnnotation) {
        guard pendingNewFreeText === annotation else { return }
        annotation.page?.removeAnnotation(annotation)
        pendingNewFreeText = nil
        selectedAnnotation = nil
        isDirty = pendingFreeTextWasDirty
        activeTool = .select
        statusMessage = "Unsaved text removed"
        pdfView?.refreshInteractionAppearance()
        objectWillChange.send()
    }

    func importSignatureImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a signature image, preferably with a transparent background"
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        signatureImage = image
        savedSignature = []
        activeTool = .signature
        showSignaturePad = false
        pdfView?.needsDisplay = true
        statusMessage = "Signature image ready: click the page to place it"
    }

    func useDrawnSignature(_ strokes: [[CGPoint]]) {
        savedSignature = strokes
        signatureImage = nil
        activeTool = .signature
        pdfView?.needsDisplay = true
    }

    func updateSearch() {
        guard let document = pdfDocument else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        searchIndex = 0
        if let first = searchResults.first { pdfView?.setCurrentSelection(first, animate: true) }
        statusMessage = query.isEmpty ? "\(pageCount) pages" : "\(searchResults.count) results"
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func nextSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + direction + searchResults.count) % searchResults.count
        pdfView?.setCurrentSelection(searchResults[searchIndex], animate: true)
    }

    func setPageLayout(_ layout: PageLayoutMode) {
        pageLayout = layout
        pdfView?.displayMode = layout.pdfMode
        pdfView?.autoScales = true
    }

    func activateSelectTool() {
        if pendingNewNote != nil {
            cancelNoteEditing()
            return
        }
        if let annotation = pendingNewFreeText {
            editingFreeText = annotation
            cancelFreeTextEditing()
            return
        }
        activeTool = .select
        pdfView?.cancelActiveInteraction()
        statusMessage = "Select tool"
    }

    func activateTool(_ tool: CanvasTool) {
        if tool == .select {
            activateSelectTool()
            return
        }
        selectAnnotation(nil)
        activeTool = tool
        pdfView?.cancelActiveInteraction()
        statusMessage = "\(tool.label) tool"
    }

    func fitPage() { pdfView?.autoScales = true }
    func actualSize() { pdfView?.scaleFactor = 1.0 }
    func zoom(by factor: CGFloat) { pdfView?.scaleFactor = max(0.25, min((pdfView?.scaleFactor ?? 1) * factor, 5)) }

    func recognizeCurrentPage() {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        statusMessage = "Recognizing text…"
        let thumbnail = page.thumbnail(of: CGSize(width: 1800, height: 2400), for: .mediaBox)
        guard let cgImage = thumbnail.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let request = VNRecognizeTextRequest { [weak self] request, error in
            let text = (request.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n") ?? ""
            DispatchQueue.main.async {
                guard let self else { return }
                if let error { self.presentError(error.localizedDescription); return }
                self.ocrText = text
                self.showOCRResult = true
                self.statusMessage = text.isEmpty ? "No text recognized" : "Text recognized"
            }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cgImage).perform([request])
        }
    }

    func changePageBox(_ box: PDFDisplayBox, inset: CGFloat) {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        let bounds = page.bounds(for: box).insetBy(dx: inset, dy: inset)
        guard bounds.width > 50, bounds.height > 50 else { return }
        let wasDirty = isDirty
        let oldBounds = page.bounds(for: box)
        page.setBounds(bounds, for: box)
        registerEdit(wasDirtyBefore: wasDirty, undo: { page.setBounds(oldBounds, for: box) }, redo: { page.setBounds(bounds, for: box) })
        changed("Page margins changed")
    }

    func resetCurrentCrop() {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        let oldBounds = page.bounds(for: .cropBox)
        let newBounds = page.bounds(for: .mediaBox)
        guard oldBounds != newBounds else { return }
        let wasDirty = isDirty
        page.setBounds(newBounds, for: .cropBox)
        registerEdit(wasDirtyBefore: wasDirty, undo: { page.setBounds(oldBounds, for: .cropBox) }, redo: { page.setBounds(newBounds, for: .cropBox) })
        changed("Crop reset")
    }

    func registerAnnotationGeometryChange(
        _ annotation: PDFAnnotation,
        from oldBounds: CGRect,
        oldPaths: [NSBezierPath],
        to newBounds: CGRect,
        newPaths: [NSBezierPath],
        wasDirtyBefore: Bool
    ) {
        guard oldBounds != newBounds || !pathsEqual(oldPaths, newPaths) else { return }
        registerEdit(wasDirtyBefore: wasDirtyBefore, undo: {
            applyGeometry(to: annotation, bounds: oldBounds, paths: oldPaths)
        }, redo: {
            applyGeometry(to: annotation, bounds: newBounds, paths: newPaths)
        })
    }

    private func registerEdit(wasDirtyBefore: Bool, undo: @escaping () -> Void, redo: @escaping () -> Void) {
        undoActions.append(PDFEditAction(undo: undo, redo: redo, wasDirtyBefore: wasDirtyBefore))
        if undoActions.count > 100 { undoActions.removeFirst() }
        redoActions.removeAll()
        objectWillChange.send()
    }

    func undo() {
        guard let action = undoActions.popLast() else {
            pdfView?.undoManager?.undo()
            return
        }
        action.undo()
        redoActions.append(action)
        isDirty = action.wasDirtyBefore
        finishHistoryChange("Change undone")
    }

    func redo() {
        guard let action = redoActions.popLast() else {
            pdfView?.undoManager?.redo()
            return
        }
        action.redo()
        undoActions.append(action)
        isDirty = true
        finishHistoryChange("Change redone")
    }

    private func finishHistoryChange(_ message: String) {
        if let document = pdfDocument {
            currentPageIndex = max(0, min(currentPageIndex, document.pageCount - 1))
        }
        statusMessage = message
        synchronizeSelectedShapeAppearance()
        synchronizeSelectedTextAppearance()
        pdfView?.needsDisplay = true
        pdfView?.refreshInteractionAppearance()
        objectWillChange.send()
    }

    func changed(_ message: String) {
        isDirty = true
        statusMessage = message
        pdfView?.needsDisplay = true
        objectWillChange.send()
    }

    private func chooseSaveURL(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func requestPassword(title: String, message: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSSecureTextField(frame: CGRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func presentError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "zzPDF"
        alert.informativeText = message
        alert.runModal()
    }
}

private func removePage(_ page: PDFPage, from document: PDFDocument) {
    let index = document.index(for: page)
    if index != NSNotFound { document.removePage(at: index) }
}

private func movePage(_ page: PDFPage, in document: PDFDocument, to index: Int) {
    removePage(page, from: document)
    document.insert(page, at: min(max(index, 0), document.pageCount))
}

private func applyGeometry(to annotation: PDFAnnotation, bounds: CGRect, paths: [NSBezierPath]) {
    if let scalableInk = annotation as? ScalableInkAnnotation {
        scalableInk.resize(to: bounds)
        return
    }
    annotation.bounds = bounds
    guard annotation.isSubtype(.ink) else { return }
    for path in annotation.paths ?? [] { annotation.remove(path) }
    for path in paths { if let copy = path.copy() as? NSBezierPath { annotation.add(copy) } }
}

private func pathsEqual(_ lhs: [NSBezierPath], _ rhs: [NSBezierPath]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { $0.0.bounds == $0.1.bounds && $0.0.elementCount == $0.1.elementCount }
}
