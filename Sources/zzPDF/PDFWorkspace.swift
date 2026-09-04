import AppKit
import PDFKit
import SwiftUI
@preconcurrency import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, note, text, draw, rectangle, oval, redact, signature

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: "Select"
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
        case .note: "note.text"
        case .text: "textformat"
        case .draw: "pencil.tip"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .redact: "eye.slash"
        case .signature: "signature"
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

private struct PDFHistoryState {
    let data: Data
    let pageIndex: Int
    let wasDirty: Bool
}

@MainActor
final class PDFWorkspace: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var activeTool: CanvasTool = .select
    @Published var pageLayout: PageLayoutMode = .continuous
    @Published var annotationColor: Color = .yellow
    @Published var lineWidth: Double = 2.5
    @Published var textToInsert = "Text"
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var sidebarVisible = true
    @Published var inspectorVisible = true
    @Published var showSignaturePad = false
    @Published var showPasswordExport = false
    @Published var showOCRResult = false
    @Published var showNoteEditor = false
    @Published var ocrText = ""
    @Published var annotationDraftText = ""
    @Published var statusMessage = "Open a PDF to get started"
    @Published var isDirty = false
    @Published var savedSignature: [[CGPoint]] = []
    @Published var signatureImage: NSImage?

    private var undoStates: [PDFHistoryState] = []
    private var redoStates: [PDFHistoryState] = []

    weak var pdfView: InteractivePDFView?

    var hasDocument: Bool { pdfDocument != nil }
    var pageCount: Int { pdfDocument?.pageCount ?? 0 }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var nsAnnotationColor: NSColor { NSColor(annotationColor) }
    var hasSignature: Bool { !savedSignature.isEmpty || signatureImage != nil }
    var canUndo: Bool { !undoStates.isEmpty || pdfView?.undoManager?.canUndo == true }
    var canRedo: Bool { !redoStates.isEmpty || pdfView?.undoManager?.canRedo == true }

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
        undoStates.removeAll()
        redoStates.removeAll()
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
        recordUndoState()
        var insertionIndex = min(currentPageIndex + 1, document.pageCount)
        for url in panel.urls {
            guard let extra = PDFDocument(url: url), !extra.isLocked else { continue }
            for index in 0..<extra.pageCount {
                if let page = extra.page(at: index)?.copy() as? PDFPage {
                    document.insert(page, at: insertionIndex)
                    insertionIndex += 1
                }
            }
        }
        changed("PDFs merged")
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = true
        panel.message = "Each image will become a page"
        guard panel.runModal() == .OK else { return }
        if pdfDocument != nil { recordUndoState() }
        let destination = pdfDocument ?? PDFDocument()
        for url in panel.urls {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                destination.insert(page, at: destination.pageCount)
            }
        }
        if destination.pageCount > 0 {
            pdfDocument = destination
            fileURL = nil
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
        recordUndoState()
        document.removePage(at: currentPageIndex)
        document.insert(page, at: target)
        currentPageIndex = target
        changed("Page moved")
        selectPage(target)
    }

    func duplicateCurrentPage() {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex)?.copy() as? PDFPage else { return }
        recordUndoState()
        document.insert(page, at: currentPageIndex + 1)
        changed("Page duplicated")
        selectPage(currentPageIndex + 1)
    }

    func deleteCurrentPage() {
        guard let document = pdfDocument, document.pageCount > 0 else { return }
        recordUndoState()
        document.removePage(at: currentPageIndex)
        currentPageIndex = max(0, min(currentPageIndex, document.pageCount - 1))
        changed("Page deleted")
        if document.pageCount > 0 { selectPage(currentPageIndex) }
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        recordUndoState()
        page.rotation = (page.rotation + degrees + 360) % 360
        changed("Page rotated")
    }

    func addMarkup(_ kind: MarkupKind) {
        guard let selection = pdfView?.currentSelection else {
            statusMessage = "Select text in the document first"
            return
        }
        recordUndoState()
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
            annotation.color = kind == .highlight ? nsAnnotationColor.withAlphaComponent(0.45) : nsAnnotationColor
            page.addAnnotation(annotation)
        }
        pdfView?.clearSelection()
        changed("Annotation added")
    }

    func addAnnotation(at point: CGPoint, on page: PDFPage, dragPoints: [CGPoint] = []) {
        let color = nsAnnotationColor
        let annotation: PDFAnnotation?
        let tool = activeTool
        switch tool {
        case .select:
            return
        case .note:
            let item = PDFAnnotation(bounds: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
            item.contents = ""
            item.color = color
            annotation = item
        case .text:
            let item = PDFAnnotation(bounds: CGRect(x: point.x, y: point.y - 20, width: 210, height: 34), forType: .freeText, withProperties: nil)
            item.contents = textToInsert
            item.font = .systemFont(ofSize: 15)
            item.fontColor = color
            item.color = .clear
            annotation = item
        case .rectangle, .oval:
            let rect = normalizedBounds(from: dragPoints, fallback: point, size: CGSize(width: 130, height: 80))
            let item = PDFAnnotation(bounds: rect, forType: tool == .rectangle ? .square : .circle, withProperties: nil)
            item.color = color
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
            recordUndoState()
            page.addAnnotation(annotation)
            selectAnnotation(annotation)
            changed("Annotation added")
            if tool == .note {
                activeTool = .select
                annotationDraftText = ""
                showNoteEditor = true
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
        let path = NSBezierPath()
        path.move(to: CGPoint(x: points[0].x - bounds.minX, y: points[0].y - bounds.minY))
        for point in points.dropFirst() {
            path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY))
        }
        let item = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        item.color = color
        let border = PDFBorder()
        border.lineWidth = width
        item.border = border
        item.add(path)
        return item
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
        recordUndoState()
        page.removeAnnotation(annotation)
        selectAnnotation(nil)
        changed("Annotation removed")
    }

    func selectAnnotation(_ annotation: PDFAnnotation?) {
        selectedAnnotation = annotation
        pdfView?.refreshInteractionAppearance()
    }

    func beginEditingSelectedNote(recordHistory: Bool = true) {
        guard let annotation = selectedAnnotation, annotation.type == PDFAnnotationSubtype.text.rawValue else { return }
        if recordHistory { recordUndoState() }
        annotationDraftText = annotation.contents ?? ""
        showNoteEditor = true
    }

    func commitSelectedNote() {
        selectedAnnotation?.contents = annotationDraftText
        showNoteEditor = false
        changed("Note updated")
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
        recordUndoState()
        page.setBounds(bounds, for: box)
        changed("Page margins changed")
    }

    func recordUndoState() {
        guard let document = pdfDocument, let data = document.dataRepresentation() else { return }
        undoStates.append(PDFHistoryState(data: data, pageIndex: currentPageIndex, wasDirty: isDirty))
        if undoStates.count > 25 { undoStates.removeFirst() }
        redoStates.removeAll()
        objectWillChange.send()
    }

    func undo() {
        guard let previous = undoStates.popLast() else {
            pdfView?.undoManager?.undo()
            return
        }
        guard let current = makeHistoryState() else { return }
        redoStates.append(current)
        restoreHistoryState(previous, message: "Change undone")
    }

    func redo() {
        guard let next = redoStates.popLast() else {
            pdfView?.undoManager?.redo()
            return
        }
        guard let current = makeHistoryState() else { return }
        undoStates.append(current)
        restoreHistoryState(next, message: "Change redone")
    }

    private func makeHistoryState() -> PDFHistoryState? {
        guard let data = pdfDocument?.dataRepresentation() else { return nil }
        return PDFHistoryState(data: data, pageIndex: currentPageIndex, wasDirty: isDirty)
    }

    private func restoreHistoryState(_ state: PDFHistoryState, message: String) {
        guard let document = PDFDocument(data: state.data) else { return }
        pdfDocument = document
        currentPageIndex = min(state.pageIndex, max(document.pageCount - 1, 0))
        isDirty = state.wasDirty
        selectedAnnotation = nil
        statusMessage = message
        objectWillChange.send()
    }

    func changed(_ message: String) {
        isDirty = true
        statusMessage = message
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
