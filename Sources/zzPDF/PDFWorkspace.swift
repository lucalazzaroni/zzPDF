import AppKit
import PDFKit
import SwiftUI
@preconcurrency import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, fillForms, editText, highlight, underline, strikeOut, note, text, draw, rectangle, oval, redact, signature

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: "Select"
        case .fillForms: "Fill Forms"
        case .editText: "Edit Text"
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
        case .editText: "character.cursor.ibeam"
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

private final class CoverLink {
    let cover: PDFAnnotation
    var alignedTextBounds: CGRect

    init(cover: PDFAnnotation, alignedTextBounds: CGRect) {
        self.cover = cover
        self.alignedTextBounds = alignedTextBounds
    }
}

private struct TextEditSession {
    let annotation: PDFAnnotation
    let cover: PDFAnnotation?
    let page: PDFPage
    let isNew: Bool
    let multiline: Bool
    let baseline: CGFloat
    let wasDirtyBefore: Bool
    let contents: String
    let font: NSFont?
    let bounds: CGRect
    let coverBounds: CGRect?
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
    @Published var annotationColor: Color = .black { didSet { preferences.annotationColor = annotationColor } }
    @Published var lineWidth: Double = 2.5 { didSet { preferences.lineWidth = lineWidth } }
    @Published var shapeHasFill = false { didSet { preferences.shapeHasFill = shapeHasFill } }
    @Published var shapeFillColor: Color = .black { didSet { preferences.shapeFillColor = shapeFillColor } }
    @Published var selectedShapeStrokeWidth: Double = 2.5
    @Published var selectedShapeHasFill = false
    @Published var selectedShapeFillColor: Color = .black
    @Published var textToInsert = "Text"
    @Published var textFontSize: Double = 15 { didSet { preferences.textFontSize = textFontSize } }
    @Published var selectedTextFontSize: Double = 15
    @Published var selectedTextColor: Color = .black
    @Published var selectedTextBackground: Color = .white
    @Published var selectedTextAlignment: NSTextAlignment = .left
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var searchFocusRequest = 0
    @Published var sidebarVisible = true { didSet { preferences.sidebarVisible = sidebarVisible } }
    @Published var inspectorVisible = true { didSet { preferences.inspectorVisible = inspectorVisible } }
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
    @Published var isDirty = false {
        didSet {
            if isDirty {
                scheduleTemporaryAutosave()
            } else if oldValue {
                clearTemporaryAutosave()
            }
        }
    }
    @Published var savedSignature: [[CGPoint]] = []
    @Published var signatureImage: NSImage?

    let preferences: AppPreferences
    private let recoveryStore: TemporaryRecoveryStore

    private var undoActions: [PDFEditAction] = []
    private var redoActions: [PDFEditAction] = []
    private var noteOriginalText: String?
    private var pendingNewNote: PDFAnnotation?
    private var pendingNoteWasDirty = false
    private var pendingNewFreeText: PDFAnnotation?
    private var pendingFreeTextWasDirty = false
    private var editingFreeText: PDFAnnotation?
    private var activeTextEdit: TextEditSession?
    private var coversByText: [ObjectIdentifier: CoverLink] = [:]
    private var textsByCover: [ObjectIdentifier: PDFAnnotation] = [:]
    private var shapeStrokeBeforeEditing: Double?
    private var shapeStrokeWasDirty = false
    private var textSizeBeforeEditing: Double?
    private var textSizeWasDirty = false
    private var activeSearchQuery = ""
    private var didAttemptSessionRestore = false
    private var sessionDiscarded = false
    private var pendingRestoredPageIndex: Int?
    private var pendingRestoredZoom: Double?
    private var restoringViewState = false
    private var recoveryIdentifier = UUID()
    private var temporaryAutosaveWorkItem: DispatchWorkItem?

    weak var pdfView: InteractivePDFView?

    var hasDocument: Bool { pdfDocument != nil }
    var pageCount: Int { pdfDocument?.pageCount ?? 0 }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    var nsAnnotationColor: NSColor { NSColor(annotationColor) }
    var hasSignature: Bool { !savedSignature.isEmpty || signatureImage != nil }
    var selectedAnnotationIsShape: Bool {
        guard let annotation = selectedAnnotation else { return false }
        if annotation.contents == RedactionFlattener.marker { return false }
        return annotation.isSubtype(.square) || annotation.isSubtype(.circle)
    }
    var selectedAnnotationIsFreeText: Bool {
        selectedAnnotation?.isSubtype(.freeText) == true
    }
    var canUndo: Bool { !undoActions.isEmpty || pdfView?.undoManager?.canUndo == true }
    var canRedo: Bool { !redoActions.isEmpty || pdfView?.undoManager?.canRedo == true }

    init(
        preferences: AppPreferences = AppPreferences(),
        recoveryStore: TemporaryRecoveryStore? = nil
    ) {
        self.preferences = preferences
        self.recoveryStore = recoveryStore ?? .shared
        pageLayout = preferences.defaultPageLayout
        activeTool = preferences.initialTool
        sidebarVisible = preferences.sidebarVisible
        inspectorVisible = preferences.inspectorVisible
        annotationColor = preferences.annotationColor
        lineWidth = preferences.lineWidth
        textFontSize = preferences.textFontSize
        shapeHasFill = preferences.shapeHasFill
        shapeFillColor = preferences.shapeFillColor
        self.recoveryStore.reserve(recoveryIdentifier)
    }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a PDF document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        load(url, rememberSession: true)
    }

    private func load(_ url: URL, rememberSession: Bool) {
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
        prepareToReplaceCurrentDocument()
        pdfDocument = document
        fileURL = url
        currentPageIndex = 0
        activeTool = preferences.initialTool
        pageLayout = preferences.defaultPageLayout
        selectedAnnotation = nil
        hasTextSelection = false
        pendingNewNote = nil
        pendingNewFreeText = nil
        activeTextEdit = nil
        sessionDiscarded = false
        rebuildTextReplacementLinks()
        undoActions.removeAll()
        redoActions.removeAll()
        isDirty = false
        searchText = ""
        searchResults = []
        activeSearchQuery = ""
        statusMessage = "\(document.pageCount) pages"
        if rememberSession {
            preferences.rememberDocument(url, pageIndex: 0, zoom: 0, layout: pageLayout)
        }
    }

    func save() {
        _ = saveForClosing()
    }

    /// Closes an open in-place editor so its text reaches the page before it is written out.
    func finishActiveTextEditing() {
        guard activeTextEdit != nil else { return }
        pdfView?.commitInlineTextEditing()
    }

    @discardableResult
    func saveForClosing() -> Bool {
        finishActiveTextEditing()
        guard let document = pdfDocument else { return true }
        guard let url = fileURL else { return saveAsDocument() }
        if document.write(to: url) {
            isDirty = false
            statusMessage = "Saved"
            return true
        } else {
            presentError("The document could not be saved.")
            return false
        }
    }

    func saveAs() {
        _ = saveAsDocument()
    }

    func makePrintOperation(using printInfo: NSPrintInfo = .shared) -> NSPrintOperation? {
        guard let document = pdfDocument else { return nil }
        let operation = document.printOperation(
            for: printInfo,
            scalingMode: .pageScaleToFit,
            autoRotate: true
        )
        operation?.showsPrintPanel = true
        operation?.showsProgressPanel = true
        return operation
    }

    func printDocument() {
        finishActiveTextEditing()
        guard let operation = makePrintOperation() else {
            presentError("The document could not be prepared for printing.")
            return
        }
        operation.run()
    }

    @discardableResult
    private func saveAsDocument() -> Bool {
        finishActiveTextEditing()
        guard let document = pdfDocument,
              let url = chooseSaveURL(defaultName: "\(displayName).pdf")
        else { return false }
        if document.write(to: url) {
            fileURL = url
            isDirty = false
            statusMessage = "Copy saved"
            preferences.rememberDocument(
                url,
                pageIndex: currentPageIndex,
                zoom: Double(pdfView?.scaleFactor ?? 0),
                layout: pageLayout
            )
            return true
        } else {
            presentError("The document could not be saved.")
            return false
        }
    }

    func exportFlattened() {
        finishActiveTextEditing()
        guard let document = pdfDocument else { return }
        let redactedPages = RedactionFlattener.redactedPageIndexes(in: document)
        if preferences.confirmFlattenedExport,
           !confirmAction(
               title: "Export Flattened Copy?",
               message: RedactionFlattener.exportWarning(redactedPageCount: redactedPages.count)
           ) { return }
        guard let url = chooseSaveURL(defaultName: "\(displayName)-flattened.pdf") else { return }
        if writeFlattenedCopy(of: document, to: url, extraOptions: [:]) {
            statusMessage = redactedPages.isEmpty
                ? "Flattened copy exported"
                : "Flattened copy exported, \(redactedPages.count) redacted page\(redactedPages.count == 1 ? "" : "s") rasterized"
        } else {
            presentError("The export failed.")
        }
    }

    /// Writes a copy in which annotations are part of the page. Redacted pages are
    /// rasterized first: burning in a black rectangle only hides the text visually, and
    /// the words underneath stay selectable and searchable in the exported file.
    private func writeFlattenedCopy(
        of document: PDFDocument,
        to url: URL,
        extraOptions: [PDFDocumentWriteOption: Any]
    ) -> Bool {
        var options: [PDFDocumentWriteOption: Any] = extraOptions
        options[.burnInAnnotationsOption] = true
        guard let flattened = RedactionFlattener.rasterizingRedactedPages(of: document) else {
            options[.saveImagesAsJPEGOption] = true
            options[.optimizeImagesForScreenOption] = true
            return document.write(to: url, withOptions: options)
        }
        return flattened.write(to: url, withOptions: options)
    }

    func exportProtected(ownerPassword: String, userPassword: String, flatten: Bool) {
        finishActiveTextEditing()
        guard let document = pdfDocument,
              !ownerPassword.isEmpty,
              let url = chooseSaveURL(defaultName: "\(displayName)-protected.pdf") else { return }
        var options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: ownerPassword]
        if !userPassword.isEmpty { options[.userPasswordOption] = userPassword }
        let succeeded = flatten
            ? writeFlattenedCopy(of: document, to: url, extraOptions: options)
            : document.write(to: url, withOptions: options)
        if succeeded {
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
        var skipped = 0
        for url in panel.urls {
            guard let extra = PDFDocument(url: url), !extra.isLocked else {
                skipped += 1
                continue
            }
            for index in 0..<extra.pageCount {
                if let page = extra.page(at: index)?.copy() as? PDFPage {
                    document.insert(page, at: insertionIndex)
                    inserted.append((page, insertionIndex))
                    insertionIndex += 1
                }
            }
        }
        guard !inserted.isEmpty else {
            presentError(skipped == 1
                ? "That PDF is password protected and could not be merged."
                : "Those PDFs are password protected and could not be merged.")
            return
        }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            for (page, _) in inserted.reversed() { removePage(page, from: document) }
        }, redo: {
            for (page, index) in inserted { document.insert(page, at: min(index, document.pageCount)) }
        })
        changed(skipped == 0 ? "PDFs merged" : "PDFs merged, \(skipped) skipped because they are protected")
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
        guard !inserted.isEmpty else { return }
        if !hadDocument {
            pdfDocument = destination
            fileURL = nil
        }
        registerEdit(wasDirtyBefore: wasDirty, undo: { [weak self] in
            for (page, _) in inserted.reversed() { removePage(page, from: destination) }
            if !hadDocument { self?.pdfDocument = nil }
        }, redo: { [weak self] in
            if !hadDocument { self?.pdfDocument = destination }
            for (page, index) in inserted where destination.index(for: page) == NSNotFound {
                destination.insert(page, at: min(index, destination.pageCount))
            }
        })
        changed(hadDocument ? "Images added as pages" : "Images imported")
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
        rememberCurrentView()
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
        guard document.pageCount > 1 else {
            statusMessage = "A document needs at least one page"
            return
        }
        if preferences.confirmPageDeletion,
           !confirmAction(title: "Delete Page?", message: "You can undo this action with Command-Z.") { return }
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
        case .select, .fillForms, .editText, .highlight, .underline, .strikeOut:
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
            item.contents = RedactionFlattener.marker
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
        let cover = linkedCover(for: annotation)
        page.removeAnnotation(annotation)
        if let cover { page.removeAnnotation(cover) }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            if let cover { page.addAnnotation(cover) }
            page.addAnnotation(annotation)
        }, redo: {
            page.removeAnnotation(annotation)
            if let cover { page.removeAnnotation(cover) }
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
        selectedTextColor = Color(nsColor: annotation.fontColor ?? .black)
        selectedTextAlignment = annotation.alignment
        let background = linkedCover(for: annotation)?.interiorColor ?? annotation.color
        selectedTextBackground = Color(nsColor: background)
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
        let resized: NSFont
        if currentFont.fontName.hasPrefix(".") {
            resized = .systemFont(ofSize: size)
        } else {
            resized = NSFontManager.shared.convert(currentFont, toSize: size)
        }
        if TextEditMarker.isTextEdit(annotation) {
            applyTextFont(resized, to: annotation)
        } else {
            annotation.font = resized
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

    func updateFormText(in annotation: PDFAnnotation, to value: String, fontSize: Double) {
        guard annotation.isSubtype(.widget), annotation.widgetFieldType == .text else { return }
        let oldValue = annotation.widgetStringValue ?? ""
        let oldFont = annotation.font
        let oldFontSize = Double(oldFont?.pointSize ?? 14)
        guard oldValue != value || abs(oldFontSize - fontSize) > 0.01 else { return }
        let wasDirty = isDirty
        let apply: (String, Double) -> Void = { text, size in
            annotation.widgetStringValue = text
            self.applyFontSize(size, to: annotation)
        }
        apply(value, fontSize)
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: {
                annotation.widgetStringValue = oldValue
                annotation.font = oldFont
            },
            redo: { apply(value, fontSize) }
        )
        changed("Form field updated")
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

    // MARK: - Editing existing page text

    var selectedAnnotationIsTextReplacement: Bool {
        guard let annotation = selectedAnnotation else { return false }
        return TextEditMarker.isTextEdit(annotation) && annotation.isSubtype(.freeText)
    }

    func replaceableText(at point: CGPoint, on page: PDFPage) -> ReplaceableText? {
        PageTextScanner.replaceableText(at: point, on: page)
    }

    func replaceableTextBounds(at point: CGPoint, on page: PDFPage) -> CGRect? {
        PageTextScanner.lineBounds(at: point, on: page)
    }

    func beginTextReplacement(at point: CGPoint, on page: PDFPage) {
        guard let replacement = PageTextScanner.replaceableText(at: point, on: page) else {
            statusMessage = "No editable text here"
            return
        }
        beginTextReplacement(replacement)
    }

    func beginTextReplacement(in rect: CGRect, on page: PDFPage) {
        guard let replacement = PageTextScanner.replaceableText(in: rect, on: page) else {
            statusMessage = "No editable text in the selected area"
            return
        }
        beginTextReplacement(replacement)
    }

    func beginTextReplacement(_ replacement: ReplaceableText) {
        pdfView?.cancelInlineTextEditing()
        let page = replacement.page
        let wasDirty = isDirty
        let identifier = TextEditMarker.makeIdentifier()
        let bounds = replacement.textBounds

        let cover = PDFAnnotation(
            bounds: FreeTextLayout.coverBounds(for: bounds, font: replacement.font)
                .insetBy(dx: -FreeTextLayout.coverPadding, dy: -FreeTextLayout.coverPadding / 2),
            forType: .square,
            withProperties: nil
        )
        cover.color = replacement.backgroundColor
        cover.interiorColor = replacement.backgroundColor
        let border = PDFBorder()
        border.lineWidth = 0
        cover.border = border
        cover.userName = identifier

        let text = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
        text.contents = replacement.text
        text.font = replacement.font
        text.fontColor = replacement.fontColor
        text.color = .clear
        text.alignment = .left
        text.userName = identifier

        page.addAnnotation(cover)
        page.addAnnotation(text)
        link(cover: cover, to: text)
        activeTextEdit = TextEditSession(
            annotation: text,
            cover: cover,
            page: page,
            isNew: true,
            multiline: replacement.isMultiline,
            baseline: replacement.firstBaseline,
            wasDirtyBefore: wasDirty,
            contents: replacement.text,
            font: replacement.font,
            bounds: bounds,
            coverBounds: cover.bounds
        )
        selectAnnotation(text)
        isDirty = true
        statusMessage = "Editing page text — Escape restores the original"
        pdfView?.needsDisplay = true
        pdfView?.beginInlineTextEditing(text, on: page, singleLine: !replacement.isMultiline)
    }

    func beginInlineTextEditing(_ annotation: PDFAnnotation) {
        guard annotation.isSubtype(.freeText), let page = annotation.page else { return }
        pdfView?.cancelInlineTextEditing()
        let contents = annotation.contents ?? ""
        let multiline = contents.contains("\n")
        activeTextEdit = TextEditSession(
            annotation: annotation,
            cover: linkedCover(for: annotation),
            page: page,
            isNew: false,
            multiline: multiline,
            baseline: FreeTextLayout.baseline(of: annotation) ?? annotation.bounds.minY,
            wasDirtyBefore: isDirty,
            contents: contents,
            font: annotation.font,
            bounds: annotation.bounds,
            coverBounds: linkedCover(for: annotation)?.bounds
        )
        selectAnnotation(annotation)
        pdfView?.beginInlineTextEditing(annotation, on: page, singleLine: !multiline)
    }

    /// Reflows the annotation while the editor is open so the box the user types in is
    /// the box the page will end up with.
    @discardableResult
    func previewTextEdit(_ text: String) -> NSFont? {
        guard let session = activeTextEdit else { return nil }
        return applyTextEditLayout(text, session: session)
    }

    @discardableResult
    private func applyTextEditLayout(_ text: String, session: TextEditSession) -> NSFont? {
        guard let baseFont = session.font ?? session.annotation.font else { return nil }
        let result = TextFitting.fit(
            text: text,
            font: baseFont,
            in: session.bounds,
            multiline: session.multiline,
            within: session.page.bounds(for: .cropBox)
        )
        let top = FreeTextLayout.topEdge(forBaseline: session.baseline, font: result.font)
        let bottom = min(result.bounds.minY, top - 4)
        session.annotation.contents = text
        session.annotation.font = result.font
        session.annotation.bounds = CGRect(
            x: result.bounds.minX,
            y: bottom,
            width: result.bounds.width,
            height: top - bottom
        )
        retainCover(for: session.annotation)
        pdfView?.needsDisplay = true
        return result.font
    }

    func commitTextReplacement(_ annotation: PDFAnnotation, text: String) {
        pdfView?.detachInlineTextEditing()
        guard let session = activeTextEdit, session.annotation === annotation else {
            pdfView?.needsDisplay = true
            return
        }
        activeTextEdit = nil
        applyTextEditLayout(text, session: session)
        let page = session.page
        let cover = session.cover
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if session.isNew {
            registerEdit(wasDirtyBefore: session.wasDirtyBefore, undo: {
                page.removeAnnotation(annotation)
                if let cover { page.removeAnnotation(cover) }
            }, redo: {
                if let cover { page.addAnnotation(cover) }
                page.addAnnotation(annotation)
            })
            synchronizeSelectedTextAppearance()
            changed(isEmpty ? "Page text removed" : "Page text replaced")
            return
        }

        let newContents = annotation.contents ?? ""
        let newFont = annotation.font
        let newBounds = annotation.bounds
        let newCoverBounds = cover?.bounds
        guard newContents != session.contents || newBounds != session.bounds else {
            isDirty = session.wasDirtyBefore
            pdfView?.needsDisplay = true
            return
        }
        let previousContents = session.contents
        let previousFont = session.font
        let previousBounds = session.bounds
        let previousCoverBounds = session.coverBounds
        registerEdit(wasDirtyBefore: session.wasDirtyBefore, undo: {
            annotation.contents = previousContents
            annotation.font = previousFont
            annotation.bounds = previousBounds
            if let cover, let previousCoverBounds { cover.bounds = previousCoverBounds }
        }, redo: {
            annotation.contents = newContents
            annotation.font = newFont
            annotation.bounds = newBounds
            if let cover, let newCoverBounds { cover.bounds = newCoverBounds }
        })
        synchronizeSelectedTextAppearance()
        changed("Text updated")
    }

    func cancelTextReplacement(_ annotation: PDFAnnotation) {
        pdfView?.detachInlineTextEditing()
        guard let session = activeTextEdit, session.annotation === annotation else {
            statusMessage = "Text editing cancelled"
            pdfView?.needsDisplay = true
            pdfView?.refreshInteractionAppearance()
            return
        }
        activeTextEdit = nil
        if session.isNew {
            session.page.removeAnnotation(annotation)
            if let cover = session.cover { session.page.removeAnnotation(cover) }
            unlink(text: annotation)
            selectedAnnotation = nil
        } else {
            annotation.contents = session.contents
            annotation.font = session.font
            annotation.bounds = session.bounds
            if let cover = session.cover, let coverBounds = session.coverBounds { cover.bounds = coverBounds }
        }
        isDirty = session.wasDirtyBefore
        statusMessage = session.isNew ? "Text edit discarded" : "Text editing cancelled"
        pdfView?.needsDisplay = true
        pdfView?.refreshInteractionAppearance()
        objectWillChange.send()
    }

    /// Keeps the first baseline fixed while the point size changes, so resized text stays
    /// on the line it replaced instead of drifting down the page.
    func applyTextFont(_ font: NSFont, to annotation: PDFAnnotation) {
        let baseline = FreeTextLayout.baseline(of: annotation)
        annotation.font = font
        if let baseline, annotation.isSubtype(.freeText) {
            let bounds = annotation.bounds
            let top = FreeTextLayout.topEdge(forBaseline: baseline, font: font)
            annotation.bounds = CGRect(
                x: bounds.minX,
                y: bounds.minY,
                width: bounds.width,
                height: max(4, top - bounds.minY)
            )
        }
        retainCover(for: annotation)
    }

    func setSelectedTextColor(_ color: Color) {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.freeText) else { return }
        let newColor = NSColor(color)
        let oldColor = annotation.fontColor ?? .black
        selectedTextColor = color
        guard oldColor != newColor else { return }
        let wasDirty = isDirty
        annotation.fontColor = newColor
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { annotation.fontColor = oldColor },
            redo: { annotation.fontColor = newColor }
        )
        changed("Text color updated")
    }

    func setSelectedTextBackground(_ color: Color) {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.freeText) else { return }
        let target = linkedCover(for: annotation) ?? annotation
        let newColor = NSColor(color)
        let oldFill = target.interiorColor
        let oldColor = target.color
        selectedTextBackground = color
        let wasDirty = isDirty
        let apply: (NSColor?, NSColor) -> Void = { fill, stroke in
            if target === annotation {
                target.color = stroke
            } else {
                target.interiorColor = fill
                target.color = stroke
            }
        }
        apply(newColor, newColor)
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { apply(oldFill, oldColor) },
            redo: { apply(newColor, newColor) }
        )
        changed("Background updated")
    }

    func setSelectedTextAlignment(_ alignment: NSTextAlignment) {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.freeText) else { return }
        let oldAlignment = annotation.alignment
        selectedTextAlignment = alignment
        guard oldAlignment != alignment else { return }
        let wasDirty = isDirty
        annotation.alignment = alignment
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { annotation.alignment = oldAlignment },
            redo: { annotation.alignment = alignment }
        )
        changed("Alignment updated")
    }

    // MARK: - Replacement pairing

    func linkedCover(for annotation: PDFAnnotation) -> PDFAnnotation? {
        coversByText[ObjectIdentifier(annotation)]?.cover
    }

    func textAnnotation(forCover cover: PDFAnnotation) -> PDFAnnotation? {
        textsByCover[ObjectIdentifier(cover)]
    }

    /// Moves and scales the opaque rectangle with the replacement it belongs to. The
    /// rectangle is never recomputed from the font: it has to keep hiding the original
    /// run of page text even when the replacement reflows to a smaller size.
    func synchronizeCover(for annotation: PDFAnnotation) {
        guard let link = coversByText[ObjectIdentifier(annotation)] else { return }
        let old = link.alignedTextBounds
        let new = annotation.bounds
        defer { link.alignedTextBounds = new }
        guard old != new, old.width > 0, old.height > 0 else { return }
        let scaleX = new.width / old.width
        let scaleY = new.height / old.height
        let cover = link.cover.bounds
        link.cover.bounds = CGRect(
            x: new.minX + (cover.minX - old.minX) * scaleX,
            y: new.minY + (cover.minY - old.minY) * scaleY,
            width: cover.width * scaleX,
            height: cover.height * scaleY
        )
    }

    /// Records a reflow that must leave the opaque rectangle where it is.
    private func retainCover(for annotation: PDFAnnotation) {
        coversByText[ObjectIdentifier(annotation)]?.alignedTextBounds = annotation.bounds
    }

    private func link(cover: PDFAnnotation, to text: PDFAnnotation) {
        coversByText[ObjectIdentifier(text)] = CoverLink(cover: cover, alignedTextBounds: text.bounds)
        textsByCover[ObjectIdentifier(cover)] = text
    }

    private func unlink(text: PDFAnnotation) {
        if let link = coversByText.removeValue(forKey: ObjectIdentifier(text)) {
            textsByCover.removeValue(forKey: ObjectIdentifier(link.cover))
        }
    }

    private func rebuildTextReplacementLinks() {
        coversByText.removeAll()
        textsByCover.removeAll()
        guard let document = pdfDocument else { return }
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            var groups: [String: (text: PDFAnnotation?, cover: PDFAnnotation?)] = [:]
            for annotation in page.annotations where TextEditMarker.isTextEdit(annotation) {
                guard let key = annotation.userName else { continue }
                var group = groups[key] ?? (nil, nil)
                if annotation.isSubtype(.freeText) {
                    group.text = annotation
                } else {
                    group.cover = annotation
                }
                groups[key] = group
            }
            for group in groups.values {
                guard let text = group.text, let cover = group.cover else { continue }
                link(cover: cover, to: text)
            }
        }
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
        activeSearchQuery = query
        searchResults = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        searchIndex = 0
        if searchResults.isEmpty {
            pdfView?.clearSelection()
        } else {
            revealSearchResult(at: 0)
        }
        statusMessage = query.isEmpty ? "\(pageCount) pages" : "\(searchResults.count) results"
    }

    func submitSearch(direction: Int) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if query != activeSearchQuery {
            updateSearch()
            if direction < 0, searchResults.count > 1 {
                searchIndex = searchResults.count - 1
                revealSearchResult(at: searchIndex)
            }
            return
        }
        nextSearchResult(direction: direction)
    }

    func focusSearch() {
        searchFocusRequest += 1
    }

    func nextSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + direction + searchResults.count) % searchResults.count
        revealSearchResult(at: searchIndex)
    }

    private func revealSearchResult(at index: Int) {
        guard searchResults.indices.contains(index), let view = pdfView else { return }
        let selection = searchResults[index]
        view.setCurrentSelection(selection, animate: true)
        view.go(to: selection)
        if let page = selection.pages.first, let document = pdfDocument {
            currentPageIndex = document.index(for: page)
        }
    }

    func setPageLayout(_ layout: PageLayoutMode) {
        pageLayout = layout
        preferences.defaultPageLayout = layout
        pdfView?.displayMode = layout.pdfMode
        pdfView?.autoScales = true
        rememberCurrentView()
    }

    func activateSelectTool() {
        if let session = activeTextEdit {
            pdfView?.cancelInlineTextEditing()
            cancelTextReplacement(session.annotation)
            return
        }
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
        finishActiveTextEditing()
        selectAnnotation(nil)
        activeTool = tool
        pdfView?.cancelActiveInteraction()
        statusMessage = "\(tool.label) tool"
    }

    func fitPage() {
        pdfView?.autoScales = true
        rememberCurrentView()
    }
    func actualSize() {
        pdfView?.scaleFactor = 1.0
        rememberCurrentView()
    }
    func zoom(by factor: CGFloat) {
        pdfView?.scaleFactor = max(0.25, min((pdfView?.scaleFactor ?? 1) * factor, 5))
        rememberCurrentView()
    }

    func restorePreviousDocumentIfNeeded() {
        guard !didAttemptSessionRestore else { return }
        didAttemptSessionRestore = true
        if restoreTemporaryRecoveryIfAvailable() { return }
        guard preferences.restoreLastDocument, let url = preferences.lastDocumentURL else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            preferences.forgetLastDocument()
            return
        }
        let restoredPage = preferences.lastPageIndex
        let restoredZoom = preferences.lastZoom
        let restoredLayout = preferences.lastPageLayout
        load(url, rememberSession: false)
        guard pdfDocument != nil, fileURL == url else { return }
        pageLayout = restoredLayout
        currentPageIndex = max(0, min(restoredPage, pageCount - 1))
        pendingRestoredPageIndex = currentPageIndex
        pendingRestoredZoom = restoredZoom > 0 ? restoredZoom : nil
        restoringViewState = true
        statusMessage = "Previous document restored"
    }

    func attachPDFView(_ view: InteractivePDFView) {
        pdfView = view
    }

    func applyPendingViewRestoration() {
        guard restoringViewState, let view = pdfView, view.document === pdfDocument else { return }
        let pageIndex = pendingRestoredPageIndex ?? currentPageIndex
        let zoom = pendingRestoredZoom
        pendingRestoredPageIndex = nil
        pendingRestoredZoom = nil
        restoringViewState = false
        guard let page = pdfDocument?.page(at: pageIndex) else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, let view else { return }
            view.displayMode = self.pageLayout.pdfMode
            view.go(to: page)
            if let zoom {
                view.autoScales = false
                view.scaleFactor = max(view.minScaleFactor, min(CGFloat(zoom), view.maxScaleFactor))
            }
            self.rememberCurrentView()
        }
    }

    func recordCurrentPage(_ index: Int) {
        currentPageIndex = max(0, min(index, max(0, pageCount - 1)))
        rememberCurrentView()
    }

    func recordViewState(from view: PDFView) {
        guard !restoringViewState else { return }
        rememberCurrentView(zoom: Double(view.scaleFactor))
    }

    func refreshPreferenceAppearance() {
        pdfView?.refreshInteractionAppearance()
    }

    func applyDefaultPreferences() {
        sidebarVisible = preferences.sidebarVisible
        inspectorVisible = preferences.inspectorVisible
        annotationColor = preferences.annotationColor
        lineWidth = preferences.lineWidth
        textFontSize = preferences.textFontSize
        shapeHasFill = preferences.shapeHasFill
        shapeFillColor = preferences.shapeFillColor
        setPageLayout(preferences.defaultPageLayout)
        refreshPreferenceAppearance()
        if preferences.temporaryAutosave {
            if isDirty { scheduleTemporaryAutosave() }
        } else {
            clearTemporaryAutosave()
        }
    }

    private func rememberCurrentView(zoom: Double? = nil) {
        guard !sessionDiscarded, let url = fileURL else { return }
        preferences.rememberDocument(
            url,
            pageIndex: currentPageIndex,
            zoom: zoom ?? Double(pdfView?.scaleFactor ?? 0),
            layout: pageLayout
        )
    }

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
        registerEdit(wasDirtyBefore: wasDirtyBefore, undo: { [weak self] in
            applyGeometry(to: annotation, bounds: oldBounds, paths: oldPaths)
            self?.synchronizeCover(for: annotation)
        }, redo: { [weak self] in
            applyGeometry(to: annotation, bounds: newBounds, paths: newPaths)
            self?.synchronizeCover(for: annotation)
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

    func flushTemporaryAutosave() {
        finishActiveTextEditing()
        temporaryAutosaveWorkItem?.cancel()
        temporaryAutosaveWorkItem = nil
        guard !sessionDiscarded, preferences.temporaryAutosave, isDirty, let document = pdfDocument else { return }
        let succeeded = recoveryStore.write(
            document: document,
            identifier: recoveryIdentifier,
            originalURL: fileURL,
            displayName: displayName,
            pageIndex: currentPageIndex,
            zoom: Double(pdfView?.scaleFactor ?? 0),
            pageLayout: pageLayout
        )
        if succeeded { statusMessage = "Temporary recovery copy saved" }
    }

    func confirmDeliberateClose() -> Bool {
        guard isDirty else { return closeSessionDeliberately(saving: false) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Do you want to save the changes made to “\(displayName)”?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don’t Save")
        alert.addButton(withTitle: "Cancel")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return closeSessionDeliberately(saving: true)
        case .alertSecondButtonReturn:
            return closeSessionDeliberately(saving: false)
        default:
            return false
        }
    }

    /// Ends the session for a window the user closed on purpose. Once this runs the
    /// document must not come back on the next launch, so everything that could bring it
    /// back — the recovery copy, the remembered document, a late view update — is shut off.
    @discardableResult
    func closeSessionDeliberately(saving: Bool) -> Bool {
        if saving, !saveForClosing() { return false }
        sessionDiscarded = true
        clearTemporaryAutosave()
        if let rememberedURL = preferences.lastDocumentURL,
           let fileURL,
           rememberedURL.standardizedFileURL == fileURL.standardizedFileURL {
            preferences.forgetLastDocument()
        }
        return true
    }

    /// Records the document for the next launch while the app is shutting down, so a
    /// window that is still open is remembered even when another window was closed first.
    func rememberSessionForTermination() {
        guard !sessionDiscarded, fileURL != nil else { return }
        rememberCurrentView()
    }

    func prepareForApplicationTermination() {
        flushTemporaryAutosave()
    }

    private func scheduleTemporaryAutosave() {
        guard !sessionDiscarded, preferences.temporaryAutosave, pdfDocument != nil else { return }
        temporaryAutosaveWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.flushTemporaryAutosave()
        }
        temporaryAutosaveWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }

    private func clearTemporaryAutosave() {
        temporaryAutosaveWorkItem?.cancel()
        temporaryAutosaveWorkItem = nil
        recoveryStore.discard(recoveryIdentifier)
    }

    private func prepareToReplaceCurrentDocument() {
        if isDirty {
            flushTemporaryAutosave()
            recoveryIdentifier = UUID()
            recoveryStore.reserve(recoveryIdentifier)
        } else {
            clearTemporaryAutosave()
            recoveryIdentifier = UUID()
            recoveryStore.reserve(recoveryIdentifier)
        }
    }

    private func restoreTemporaryRecoveryIfAvailable() -> Bool {
        guard preferences.temporaryAutosave,
              let (record, document) = recoveryStore.claimLatest()
        else { return false }

        recoveryIdentifier = record.identifier
        pdfDocument = document
        activeTextEdit = nil
        rebuildTextReplacementLinks()
        if let path = record.originalPath, FileManager.default.fileExists(atPath: path) {
            fileURL = URL(fileURLWithPath: path)
        } else {
            fileURL = nil
        }
        currentPageIndex = max(0, min(record.pageIndex, max(0, document.pageCount - 1)))
        pageLayout = PageLayoutMode(rawValue: record.pageLayout) ?? preferences.defaultPageLayout
        activeTool = preferences.initialTool
        selectedAnnotation = nil
        hasTextSelection = false
        undoActions.removeAll()
        redoActions.removeAll()
        pendingRestoredPageIndex = currentPageIndex
        pendingRestoredZoom = record.zoom > 0 ? record.zoom : nil
        restoringViewState = true
        isDirty = true
        statusMessage = "Recovered unsaved changes from \(record.displayName)"
        return true
    }

    private func chooseSaveURL(defaultName: String) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = defaultName
        if !preferences.exportFolderPath.isEmpty {
            let folder = URL(fileURLWithPath: preferences.exportFolderPath)
            if FileManager.default.fileExists(atPath: folder.path) { panel.directoryURL = folder }
        }
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url
    }

    private func confirmAction(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
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
