import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
@preconcurrency import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, fillForms, editText, highlight, underline, strikeOut, note, text, draw, line, arrow, polygon, rectangle, oval, redact, signature

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
        case .line: "Line"
        case .arrow: "Arrow"
        case .polygon: "Polygon"
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
        case .line: "line.diagonal"
        case .arrow: "line.diagonal.arrow"
        case .polygon: "pentagon"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .redact: "eye.slash"
        case .signature: "signature"
        }
    }

    var isLineTool: Bool { self == .line || self == .arrow }

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

/// One line of an edit in progress: the replacement text, the rectangle hiding the
/// original, and the geometry to restore if the edit is abandoned.
private struct TextEditLine {
    let annotation: PDFAnnotation
    let cover: PDFAnnotation?
    let baseline: CGFloat
    let bounds: CGRect
    let contents: String
    let font: NSFont?
    let coverBounds: CGRect?
}

private struct TextEditSession {
    let lines: [TextEditLine]
    let page: PDFPage
    let isNew: Bool
    let wasDirtyBefore: Bool

    var annotation: PDFAnnotation { lines[0].annotation }
    var multiline: Bool { lines.count > 1 }
    /// What the editor starts with: the block as one piece of text.
    var seedText: String { lines.map(\.contents).joined(separator: "\n") }
    var annotations: [PDFAnnotation] { lines.map(\.annotation) }
    var covers: [PDFAnnotation] { lines.compactMap(\.cover) }
}

private struct PDFEditAction {
    let undo: () -> Void
    let redo: () -> Void
    let wasDirtyBefore: Bool
}

@MainActor
final class PDFWorkspace: ObservableObject {
    @Published var pdfDocument: PDFDocument? {
        didSet { observeSearch(in: pdfDocument) }
    }
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var selectedPageIndexes: Set<Int> = [0]
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
    @Published var selectedTextFontFamily = "Helvetica"
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var searchFocusRequest = 0
    @Published private(set) var isSearching = false
    @Published var searchMatchesCase = false { didSet { rerunSearchIfNeeded() } }
    @Published var searchWholeWords = false { didSet { rerunSearchIfNeeded() } }
    @Published var sidebarVisible = true { didSet { preferences.sidebarVisible = sidebarVisible } }
    @Published var inspectorVisible = true { didSet { preferences.inspectorVisible = inspectorVisible } }
    @Published var showSignaturePad = false
    @Published var showPasswordExport = false
    @Published var showPageStamp = false
    @Published var showSplit = false
    @Published var showComparison = false
    @Published private(set) var comparison: [DocumentComparer.PageResult] = []
    @Published private(set) var comparedDocument: PDFDocument?
    @Published private(set) var comparedName = ""
    @Published private(set) var isComparing = false
    @Published var splitEveryPages = 1
    @Published var splitAtContents = false
    @Published var stampOptions = PageStamper.Options()
    @Published var stampAppliesToSelectionOnly = false
    @Published var showOCRResult = false
    @Published var showNoteEditor = false
    @Published var showFreeTextEditor = false
    @Published var ocrText = ""
    @Published var annotationDraftText = ""
    @Published var freeTextDraftText = ""
    @Published var freeTextDraftFontSize: Double = 15
    @Published var statusMessage = "Open a PDF to get started"
    @Published private(set) var isRecognizingText = false
    @Published var isDirty = false {
        didSet {
            if isDirty {
                scheduleTemporaryAutosave()
            } else if oldValue {
                clearTemporaryAutosave()
            }
        }
    }
    @Published var savedSignature: [[CGPoint]] = [] {
        didSet { preferences.signatureStrokes = savedSignature }
    }
    @Published var signatureImage: NSImage? {
        didSet { preferences.signatureImageData = signatureImage?.pngData }
    }
    /// True when the document on disk asked for a password to open.
    @Published private(set) var isPasswordProtected = false
    @Published private(set) var digitalSignatures: [DigitalSignatureScanner.Signature] = []

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
    private var searchObservers: [NSObjectProtocol] = []
    private var searchMatchCounts: [ObjectIdentifier: Int] = [:]
    private var searchSnippets: [String] = []

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
    var canUndo: Bool { !undoActions.isEmpty }
    var canRedo: Bool { !redoActions.isEmpty }

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
        savedSignature = preferences.signatureStrokes
        if let data = preferences.signatureImageData { signatureImage = NSImage(data: data) }
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
        var wasLocked = false
        if document.isLocked {
            let password = requestPassword(title: "Protected PDF", message: "Enter the password to open this document.")
            guard let password, document.unlock(withPassword: password) else {
                presentError("Invalid password.")
                return
            }
            wasLocked = true
        }
        prepareToReplaceCurrentDocument()
        pdfDocument = document
        fileURL = url
        isPasswordProtected = wasLocked
        digitalSignatures = (try? Data(contentsOf: url)).map(DigitalSignatureScanner.signatures(in:)) ?? []
        preferences.noteRecentDocument(url)
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

    /// Writes a copy with the encryption removed, for a document the user has already
    /// unlocked with its password.
    func removePasswordProtection() {
        finishActiveTextEditing()
        guard let document = pdfDocument else { return }
        guard isPasswordProtected else {
            statusMessage = "This document is not password protected"
            return
        }
        guard let url = chooseSaveURL(defaultName: "\(displayName)-unprotected.pdf") else { return }
        if document.write(to: url) {
            statusMessage = "Unprotected copy saved"
        } else {
            presentError("The unprotected copy could not be written.")
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
        addImageFiles(panel.urls)
    }

    func addImageFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let wasDirty = isDirty
        let hadDocument = pdfDocument != nil
        let destination = pdfDocument ?? PDFDocument()
        var inserted: [(PDFPage, Int)] = []
        for url in urls {
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

    // MARK: - Navigating the document

    var outlineRoot: PDFOutline? {
        guard let root = pdfDocument?.outlineRoot, root.numberOfChildren > 0 else { return nil }
        return root
    }

    func goToOutline(_ outline: PDFOutline) {
        if let destination = outline.destination {
            pdfView?.go(to: destination)
        } else if let action = outline.action as? PDFActionGoTo {
            pdfView?.go(to: action.destination)
        } else {
            return
        }
        if let page = pdfView?.currentPage, let document = pdfDocument {
            currentPageIndex = document.index(for: page)
        }
        statusMessage = outline.label ?? "Section"
    }

    /// Every annotation in the document, in reading order, for the sidebar list.
    func annotationEntries() -> [AnnotationEntry] {
        guard let document = pdfDocument else { return [] }
        var entries: [AnnotationEntry] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations {
                // Form fields, the document's own hyperlinks, the popup PDFKit pairs with
                // every note, and the backdrop behind replaced text are not things the
                // reader annotated, so they stay out of the list.
                guard !annotation.isSubtype(.widget),
                      !annotation.isSubtype(.popup),
                      !annotation.isSubtype(.link),
                      !isTextReplacementCover(annotation) else { continue }
                entries.append(AnnotationEntry(annotation: annotation, pageIndex: index))
            }
        }
        return entries
    }

    private func isTextReplacementCover(_ annotation: PDFAnnotation) -> Bool {
        textAnnotation(forCover: annotation) != nil
    }

    /// Opens whichever editor suits the annotation, from the sidebar list.
    func edit(_ annotation: PDFAnnotation) {
        reveal(annotation)
        if annotation.isSubtype(.text) {
            beginEditingSelectedNote()
        } else if annotation.isSubtype(.freeText) {
            beginInlineTextEditing(annotation)
        } else {
            statusMessage = "\(AnnotationEntry(annotation: annotation, pageIndex: currentPageIndex).kind) has no text to edit"
        }
    }

    func reveal(_ annotation: PDFAnnotation) {
        guard let page = annotation.page, let document = pdfDocument else { return }
        currentPageIndex = document.index(for: page)
        pdfView?.go(to: annotation.bounds, on: page)
        selectAnnotation(annotation)
        rememberCurrentView()
    }

    func selectPage(_ index: Int) {
        guard let document = pdfDocument, index >= 0, index < document.pageCount,
              let page = document.page(at: index) else { return }
        currentPageIndex = index
        selectedPageIndexes = [index]
        pdfView?.go(to: page)
        rememberCurrentView()
    }

    // MARK: - Working on several pages at once

    func isPageSelected(_ index: Int) -> Bool {
        selectedPageIndexes.contains(index) || (selectedPageIndexes.isEmpty && index == currentPageIndex)
    }

    func togglePageSelection(_ index: Int) {
        if selectedPageIndexes.contains(index) {
            selectedPageIndexes.remove(index)
            if selectedPageIndexes.isEmpty { selectedPageIndexes = [currentPageIndex] }
        } else {
            selectedPageIndexes.insert(index)
        }
    }

    func extendPageSelection(to index: Int) {
        let range = min(currentPageIndex, index)...max(currentPageIndex, index)
        selectedPageIndexes = Set(range)
    }

    /// The pages an action applies to: the multiple selection when there is one, and the
    /// page being viewed otherwise.
    var targetPageIndexes: [Int] {
        let indexes = selectedPageIndexes.isEmpty ? [currentPageIndex] : Array(selectedPageIndexes)
        return indexes.filter { $0 >= 0 && $0 < pageCount }.sorted()
    }

    func reorderPage(from source: Int, to destination: Int) {
        guard let document = pdfDocument, source != destination,
              source >= 0, source < document.pageCount,
              destination >= 0, destination < document.pageCount,
              let page = document.page(at: source) else { return }
        let wasDirty = isDirty
        movePage(page, in: document, to: destination)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            movePage(page, in: document, to: source)
        }, redo: {
            movePage(page, in: document, to: destination)
        })
        currentPageIndex = destination
        selectedPageIndexes = [destination]
        changed("Page moved")
    }

    func rotateSelectedPages(by degrees: Int) {
        guard let document = pdfDocument else { return }
        let pages = targetPageIndexes.compactMap { document.page(at: $0) }
        guard !pages.isEmpty else { return }
        let wasDirty = isDirty
        let rotate: (Int) -> Void = { amount in
            for page in pages { page.rotation = (page.rotation + amount + 360) % 360 }
        }
        rotate(degrees)
        registerEdit(wasDirtyBefore: wasDirty, undo: { rotate(-degrees) }, redo: { rotate(degrees) })
        changed(pages.count == 1 ? "Page rotated" : "\(pages.count) pages rotated")
    }

    func duplicateSelectedPages() {
        guard let document = pdfDocument else { return }
        let indexes = targetPageIndexes
        guard !indexes.isEmpty else { return }
        let wasDirty = isDirty
        var copies: [(page: PDFPage, index: Int)] = []
        for (offset, index) in indexes.enumerated() {
            guard let copy = document.page(at: index + offset)?.copy() as? PDFPage else { continue }
            let destination = index + offset + 1
            document.insert(copy, at: destination)
            copies.append((copy, destination))
        }
        guard !copies.isEmpty else { return }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            for copy in copies.reversed() { removePage(copy.page, from: document) }
        }, redo: {
            for copy in copies where document.index(for: copy.page) == NSNotFound {
                document.insert(copy.page, at: min(copy.index, document.pageCount))
            }
        })
        selectedPageIndexes = Set(copies.map(\.index))
        changed(copies.count == 1 ? "Page duplicated" : "\(copies.count) pages duplicated")
    }

    func deleteSelectedPages() {
        guard let document = pdfDocument else { return }
        let indexes = targetPageIndexes
        guard !indexes.isEmpty else { return }
        guard document.pageCount > indexes.count else {
            statusMessage = "A document needs at least one page"
            return
        }
        if preferences.confirmPageDeletion {
            let message = indexes.count == 1
                ? "You can undo this action with Command-Z."
                : "\(indexes.count) pages will be removed. You can undo this action with Command-Z."
            guard confirmAction(title: indexes.count == 1 ? "Delete Page?" : "Delete Pages?", message: message) else { return }
        }
        let wasDirty = isDirty
        let removed: [(page: PDFPage, index: Int)] = indexes.compactMap { index in
            guard let page = document.page(at: index) else { return nil }
            return (page, index)
        }
        for entry in removed.reversed() { removePage(entry.page, from: document) }
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            for entry in removed { document.insert(entry.page, at: min(entry.index, document.pageCount)) }
        }, redo: {
            for entry in removed.reversed() { removePage(entry.page, from: document) }
        })
        currentPageIndex = max(0, min(indexes[0], document.pageCount - 1))
        selectedPageIndexes = [currentPageIndex]
        changed(removed.count == 1 ? "Page deleted" : "\(removed.count) pages deleted")
        if document.pageCount > 0 { selectPage(currentPageIndex) }
    }

    @discardableResult
    func writeSmallerCopy(to url: URL) -> Bool {
        guard let document = pdfDocument else { return false }
        return document.write(to: url, withOptions: [
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true
        ])
    }

    /// Writes each selected page as a PNG, for slides, e-mail, or anything that wants a
    /// picture rather than a PDF.
    func exportPagesAsImages() {
        guard let document = pdfDocument else { return }
        let indexes = targetPageIndexes
        guard !indexes.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export"
        panel.message = indexes.count == 1 ? "Choose where to save the image" : "Choose where to save the images"
        if !preferences.exportFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: preferences.exportFolderPath)
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let written = writePageImages(to: folder)
        guard written > 0 else {
            presentError("The pages could not be exported as images.")
            return
        }
        statusMessage = written == 1 ? "Image exported" : "\(written) images exported"
        _ = document
    }

    @discardableResult
    func writePageImages(to folder: URL, dpi: CGFloat = 200) -> Int {
        guard let document = pdfDocument else { return 0 }
        var written = 0
        for index in targetPageIndexes {
            guard let page = document.page(at: index),
                  let rendered = OCRTextLayer.render(page, dpi: dpi),
                  let data = NSBitmapImageRep(cgImage: rendered.image).representation(using: .png, properties: [:])
            else { continue }
            let url = folder.appendingPathComponent("\(displayName)-\(index + 1).png")
            if (try? data.write(to: url, options: .atomic)) != nil { written += 1 }
        }
        return written
    }

    /// Writes a copy with images recompressed for screen use, and says how much it saved.
    func exportSmallerCopy() {
        finishActiveTextEditing()
        guard pdfDocument != nil,
              let url = chooseSaveURL(defaultName: "\(displayName)-smaller.pdf") else { return }
        guard writeSmallerCopy(to: url) else {
            presentError("The smaller copy could not be written.")
            return
        }
        let newSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let oldSize = fileURL.flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) } ?? 0
        let formatter = ByteCountFormatter()
        if oldSize > 0, newSize > 0, newSize < oldSize {
            let saved = Int(((1 - Double(newSize) / Double(oldSize)) * 100).rounded())
            statusMessage = "Smaller copy saved: \(formatter.string(fromByteCount: Int64(newSize))), \(saved)% less"
        } else {
            statusMessage = "Copy saved: \(formatter.string(fromByteCount: Int64(newSize)))"
        }
    }

    // MARK: - Comparing

    var comparisonChangeCount: Int { comparison.filter(\.change.isChange).count }

    func compareWithAnotherPDF() {
        finishActiveTextEditing()
        guard let document = pdfDocument else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the other version of this document"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let other = PDFDocument(url: url), !other.isLocked else {
            presentError("That PDF could not be opened for comparison.")
            return
        }
        comparedDocument = other
        comparedName = url.deletingPathExtension().lastPathComponent
        comparison = []
        isComparing = true
        showComparison = true
        statusMessage = "Comparing with \(comparedName)…"

        Task { @MainActor in
            let results = DocumentComparer.compare(document, with: other)
            comparison = results
            isComparing = false
            let changed = results.filter(\.change.isChange).count
            statusMessage = changed == 0
                ? "The two documents match"
                : "\(changed) page\(changed == 1 ? "" : "s") differ"
        }
    }

    func comparisonImage(forPageNumber number: Int) -> NSImage? {
        let index = number - 1
        let original = (index < pageCount) ? pdfDocument?.page(at: index) : nil
        let revised = (index < (comparedDocument?.pageCount ?? 0)) ? comparedDocument?.page(at: index) : nil
        return DocumentComparer.differenceImage(original, revised)
    }

    // MARK: - Splitting

    /// Where the document would be cut: every N pages, or at each top-level entry of its
    /// own table of contents.
    var splitStartIndexes: [Int] {
        guard pageCount > 0 else { return [] }
        if splitAtContents {
            let starts = outlineStartIndexes()
            if !starts.isEmpty { return starts }
        }
        let step = max(1, splitEveryPages)
        return Array(stride(from: 0, to: pageCount, by: step))
    }

    private func outlineStartIndexes() -> [Int] {
        guard let root = outlineRoot, let document = pdfDocument else { return [] }
        var indexes: Set<Int> = [0]
        for position in 0..<root.numberOfChildren {
            guard let child = root.child(at: position) else { continue }
            let page = child.destination?.page ?? (child.action as? PDFActionGoTo)?.destination.page
            guard let page else { continue }
            let index = document.index(for: page)
            if index != NSNotFound { indexes.insert(index) }
        }
        return indexes.sorted()
    }

    var splitPartCount: Int { splitStartIndexes.count }

    func beginSplit() {
        splitEveryPages = max(1, min(splitEveryPages, max(1, pageCount)))
        splitAtContents = outlineRoot != nil && splitAtContents
        showSplit = true
    }

    func splitDocument() {
        guard pdfDocument != nil else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Split"
        panel.message = "Choose where to save the parts"
        if !preferences.exportFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: preferences.exportFolderPath)
        }
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let written = writeSplitParts(into: folder)
        showSplit = false
        guard written > 0 else {
            presentError("The document could not be split.")
            return
        }
        statusMessage = "Split into \(written) file\(written == 1 ? "" : "s")"
    }

    @discardableResult
    func writeSplitParts(into folder: URL) -> Int {
        guard let document = pdfDocument else { return 0 }
        let starts = splitStartIndexes
        guard !starts.isEmpty else { return 0 }
        var written = 0
        for (position, start) in starts.enumerated() {
            let end = position + 1 < starts.count ? starts[position + 1] : document.pageCount
            guard start < end else { continue }
            let part = PDFDocument()
            for index in start..<end {
                guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
                part.insert(page, at: part.pageCount)
            }
            guard part.pageCount > 0 else { continue }
            let name = String(format: "%@-%02d.pdf", displayName, position + 1)
            if part.write(to: folder.appendingPathComponent(name)) { written += 1 }
        }
        return written
    }

    func extractSelectedPages() {
        let indexes = targetPageIndexes
        guard !indexes.isEmpty else { return }
        let name = indexes.count == 1
            ? "Page-\(indexes[0] + 1).pdf"
            : "\(displayName)-pages.pdf"
        guard let url = chooseSaveURL(defaultName: name) else { return }
        guard writeSelectedPages(to: url) else {
            presentError("The pages could not be extracted.")
            return
        }
        statusMessage = indexes.count == 1 ? "Page extracted" : "\(indexes.count) pages extracted"
    }

    @discardableResult
    func writeSelectedPages(to url: URL) -> Bool {
        guard let document = pdfDocument else { return false }
        let output = PDFDocument()
        for index in targetPageIndexes {
            guard let page = document.page(at: index)?.copy() as? PDFPage else { continue }
            output.insert(page, at: output.pageCount)
        }
        guard output.pageCount > 0 else { return false }
        return output.write(to: url)
    }

    func remove(_ annotation: PDFAnnotation) {
        selectAnnotation(annotation)
        removeSelectedAnnotation()
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
            annotation.color = kind == .highlight
                ? nsAnnotationColor.highlightTint(alpha: preferences.highlightOpacity)
                : nsAnnotationColor
            sign(annotation)
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
        case .polygon:
            return
        case .line, .arrow:
            guard let first = dragPoints.first, let last = dragPoints.last,
                  hypot(last.x - first.x, last.y - first.y) > 3 else { return }
            annotation = makeLineAnnotation(from: first, to: last, color: color, arrow: tool == .arrow)
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
            sign(annotation)
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

    /// Stamps the author and the time onto an annotation, the way every other PDF
    /// application does, so a reader can tell who left what and when.
    ///
    /// Replaced page text is the one exception: its two annotations are paired through
    /// the author field, which is the only per-annotation string PDFKit writes back out,
    /// so they keep carrying their pair identifier instead of a name.
    func sign(_ annotation: PDFAnnotation) {
        annotation.modificationDate = Date()
        guard !TextEditMarker.isTextEdit(annotation) else { return }
        let author = preferences.annotationAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { return }
        annotation.userName = author
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

    /// PDFKit reads a line annotation's endpoints relative to its own bounds, not to the
    /// page, so both are stored as offsets inside the padded rectangle.
    private func makeLineAnnotation(from start: CGPoint, to end: CGPoint, color: NSColor, arrow: Bool) -> PDFAnnotation {
        let padding = max(12, lineWidth * 4)
        let bounds = CGRect(
            x: min(start.x, end.x) - padding,
            y: min(start.y, end.y) - padding,
            width: abs(end.x - start.x) + padding * 2,
            height: abs(end.y - start.y) + padding * 2
        )
        let item = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        item.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
        item.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY)
        if arrow { item.endLineStyle = .closedArrow }
        item.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        item.border = border
        return item
    }

    /// Polygons are drawn as straight-segment ink: PDFKit has no polygon annotation, and
    /// ink already moves, scales, and flattens correctly.
    func addPolygon(points: [CGPoint], on page: PDFPage, closed: Bool) {
        guard points.count > 1 else { return }
        var vertices = points
        if closed, let first = points.first { vertices.append(first) }
        guard let annotation = makeInkAnnotation(points: vertices, color: nsAnnotationColor, width: lineWidth) else { return }
        let wasDirty = isDirty
        sign(annotation)
        page.addAnnotation(annotation)
        selectAnnotation(annotation)
        registerEdit(wasDirtyBefore: wasDirty, undo: {
            page.removeAnnotation(annotation)
        }, redo: {
            page.addAnnotation(annotation)
        })
        changed(closed ? "Polygon added" : "Polyline added")
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
        selectedTextFontFamily = annotation.font?.familyName ?? "Helvetica"
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

    /// Saves the note being edited with the given text, the way the note sheet does.
    func commitNoteEditing(text: String) {
        annotationDraftText = text
        commitSelectedNote()
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

    // MARK: - Form data

    /// Every named form field in the document and what it currently holds.
    func formFieldValues() -> [String: String] {
        guard let document = pdfDocument else { return [:] }
        var values: [String: String] = [:]
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.isSubtype(.widget) {
                guard let name = annotation.fieldName, !name.isEmpty else { continue }
                switch annotation.widgetFieldType {
                case .button:
                    if annotation.buttonWidgetState == .onState {
                        values[name] = annotation.buttonWidgetStateString
                    } else if values[name] == nil {
                        values[name] = "Off"
                    }
                default:
                    values[name] = annotation.widgetStringValue ?? ""
                }
            }
        }
        return values
    }

    var hasFormFields: Bool { !formFieldValues().isEmpty }

    func exportFormData() {
        finishActiveTextEditing()
        let values = formFieldValues()
        guard !values.isEmpty else {
            statusMessage = "This document has no form fields"
            return
        }
        guard let url = chooseSaveURL(defaultName: "\(displayName)-form.json", type: .json) else { return }
        guard writeFormData(to: url) else {
            presentError("The form data could not be written.")
            return
        }
        statusMessage = "\(values.count) field\(values.count == 1 ? "" : "s") exported"
    }

    @discardableResult
    func writeFormData(to url: URL) -> Bool {
        let values = formFieldValues()
        guard !values.isEmpty,
              let data = try? JSONEncoder.sortedPretty.encode(values) else { return false }
        return (try? data.write(to: url, options: .atomic)) != nil
    }

    func importFormData() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose the form data to fill in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let filled = applyFormData(from: url)
        guard filled > 0 else {
            presentError("No field in this document matched that file.")
            return
        }
        statusMessage = "\(filled) field\(filled == 1 ? "" : "s") filled in"
    }

    /// Fills in every field whose name appears in the file, as one undo step.
    @discardableResult
    func applyFormData(from url: URL) -> Int {
        guard let document = pdfDocument,
              let data = try? Data(contentsOf: url),
              let values = try? JSONDecoder().decode([String: String].self, from: data),
              !values.isEmpty else { return 0 }

        var changes: [(annotation: PDFAnnotation, old: String, new: String, isButton: Bool)] = []
        for index in 0..<document.pageCount {
            guard let page = document.page(at: index) else { continue }
            for annotation in page.annotations where annotation.isSubtype(.widget) {
                guard let name = annotation.fieldName, let value = values[name] else { continue }
                if annotation.widgetFieldType == .button {
                    let onName = annotation.buttonWidgetStateString
                    let shouldBeOn = value == onName || value.caseInsensitiveCompare("on") == .orderedSame
                    let old = annotation.buttonWidgetState == .onState ? onName : "Off"
                    let new = shouldBeOn ? onName : "Off"
                    guard old != new else { continue }
                    changes.append((annotation, old, new, true))
                } else {
                    let old = annotation.widgetStringValue ?? ""
                    guard old != value else { continue }
                    changes.append((annotation, old, value, false))
                }
            }
        }
        guard !changes.isEmpty else { return 0 }

        let wasDirty = isDirty
        let apply: (Bool) -> Void = { forward in
            for change in changes {
                let value = forward ? change.new : change.old
                if change.isButton {
                    let onName = change.annotation.buttonWidgetStateString
                    change.annotation.buttonWidgetState = value == onName ? .onState : .offState
                } else {
                    change.annotation.widgetStringValue = value
                }
            }
        }
        apply(true)
        registerEdit(wasDirtyBefore: wasDirty, undo: { apply(false) }, redo: { apply(true) })
        changed("Form filled in")
        return changes.count
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
        guard !replacement.lines.isEmpty else { return }

        var lines: [TextEditLine] = []
        for line in replacement.lines {
            let bounds = replacement.textBounds(for: line)
            let identifier = TextEditMarker.makeIdentifier()

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
            text.contents = line.text
            text.font = replacement.font
            text.fontColor = replacement.fontColor
            text.color = .clear
            text.alignment = .left
            text.userName = identifier

            page.addAnnotation(cover)
            page.addAnnotation(text)
            link(cover: cover, to: text)
            lines.append(
                TextEditLine(
                    annotation: text,
                    cover: cover,
                    baseline: line.baseline,
                    bounds: bounds,
                    contents: line.text,
                    font: replacement.font,
                    coverBounds: cover.bounds
                )
            )
        }

        activeTextEdit = TextEditSession(lines: lines, page: page, isNew: true, wasDirtyBefore: wasDirty)
        selectAnnotation(lines[0].annotation)
        isDirty = true
        statusMessage = "Editing page text — Escape restores the original"
        pdfView?.needsDisplay = true
        pdfView?.beginInlineTextEditing(
            lines[0].annotation,
            on: page,
            singleLine: lines.count == 1,
            seedText: lines.map(\.contents).joined(separator: "\n"),
            frameBounds: replacement.textBounds
        )
    }

    func beginInlineTextEditing(_ annotation: PDFAnnotation) {
        guard annotation.isSubtype(.freeText), let page = annotation.page else { return }
        pdfView?.cancelInlineTextEditing()
        let contents = annotation.contents ?? ""
        let line = TextEditLine(
            annotation: annotation,
            cover: linkedCover(for: annotation),
            baseline: FreeTextLayout.baseline(of: annotation) ?? annotation.bounds.minY,
            bounds: annotation.bounds,
            contents: contents,
            font: annotation.font,
            coverBounds: linkedCover(for: annotation)?.bounds
        )
        activeTextEdit = TextEditSession(lines: [line], page: page, isNew: false, wasDirtyBefore: isDirty)
        selectAnnotation(annotation)
        pdfView?.beginInlineTextEditing(
            annotation,
            on: page,
            singleLine: !contents.contains("\n"),
            seedText: contents,
            frameBounds: annotation.bounds
        )
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
        guard let baseFont = session.lines[0].font ?? session.annotation.font else { return nil }
        let limit = session.page.bounds(for: .cropBox)

        // A block keeps the document's own line spacing: the text is spread over the boxes
        // of the lines it replaces rather than reflowed with the font's line height.
        let pieces = session.multiline
            ? LineDistributor.distribute(
                text,
                across: session.lines.map(\.bounds.width),
                font: baseFont
              )
            : [text]

        var displayedFont = baseFont
        for (index, line) in session.lines.enumerated() {
            let piece = index < pieces.count ? pieces[index] : ""
            let result = TextFitting.fit(
                text: piece,
                font: baseFont,
                in: line.bounds,
                multiline: false,
                within: limit
            )
            let top = FreeTextLayout.topEdge(forBaseline: line.baseline, font: result.font)
            let bottom = min(result.bounds.minY, top - 4)
            line.annotation.contents = piece
            line.annotation.font = result.font
            line.annotation.bounds = CGRect(
                x: result.bounds.minX,
                y: bottom,
                width: result.bounds.width,
                height: top - bottom
            )
            retainCover(for: line.annotation)
            if index == 0 { displayedFont = result.font }
        }
        pdfView?.needsDisplay = true
        return displayedFont
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
        let covers = session.covers
        let annotations = session.annotations
        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if session.isNew {
            registerEdit(wasDirtyBefore: session.wasDirtyBefore, undo: {
                for annotation in annotations { page.removeAnnotation(annotation) }
                for cover in covers { page.removeAnnotation(cover) }
            }, redo: {
                for cover in covers { page.addAnnotation(cover) }
                for annotation in annotations { page.addAnnotation(annotation) }
            })
            synchronizeSelectedTextAppearance()
            changed(isEmpty ? "Page text removed" : "Page text replaced")
            return
        }

        let before = session.lines
        let after = session.lines.map {
            ($0.annotation, $0.annotation.contents ?? "", $0.annotation.font, $0.annotation.bounds, $0.cover?.bounds)
        }
        let unchanged = zip(before, after).allSatisfy { line, current in
            line.contents == current.1 && line.bounds == current.3
        }
        guard !unchanged else {
            isDirty = session.wasDirtyBefore
            pdfView?.needsDisplay = true
            return
        }
        registerEdit(wasDirtyBefore: session.wasDirtyBefore, undo: {
            for line in before {
                line.annotation.contents = line.contents
                line.annotation.font = line.font
                line.annotation.bounds = line.bounds
                if let cover = line.cover, let bounds = line.coverBounds { cover.bounds = bounds }
            }
        }, redo: {
            for (index, state) in after.enumerated() {
                state.0.contents = state.1
                state.0.font = state.2
                state.0.bounds = state.3
                if let cover = before[index].cover, let bounds = state.4 { cover.bounds = bounds }
            }
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
            for line in session.lines {
                session.page.removeAnnotation(line.annotation)
                if let cover = line.cover { session.page.removeAnnotation(cover) }
                unlink(text: line.annotation)
            }
            selectedAnnotation = nil
        } else {
            for line in session.lines {
                line.annotation.contents = line.contents
                line.annotation.font = line.font
                line.annotation.bounds = line.bounds
                if let cover = line.cover, let bounds = line.coverBounds { cover.bounds = bounds }
            }
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

    var selectedTextIsBold: Bool { selectedTextHasTrait(.boldFontMask) }
    var selectedTextIsItalic: Bool { selectedTextHasTrait(.italicFontMask) }

    private func selectedTextHasTrait(_ trait: NSFontTraitMask) -> Bool {
        guard let font = selectedAnnotation?.font else { return false }
        return NSFontManager.shared.traits(of: font).contains(trait)
    }

    func setSelectedTextFontFamily(_ family: String) {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.freeText),
              let current = annotation.font else { return }
        selectedTextFontFamily = family
        let manager = NSFontManager.shared
        guard let replacement = manager.font(
            withFamily: family,
            traits: manager.traits(of: current),
            weight: manager.weight(of: current),
            size: current.pointSize
        ), replacement.fontName != current.fontName else { return }
        applyFontChange(replacement, to: annotation, message: "Font changed")
    }

    func toggleSelectedTextTrait(bold: Bool) {
        guard let annotation = selectedAnnotation, annotation.isSubtype(.freeText),
              let current = annotation.font else { return }
        let manager = NSFontManager.shared
        let trait: NSFontTraitMask = bold ? .boldFontMask : .italicFontMask
        let replacement = manager.traits(of: current).contains(trait)
            ? manager.convert(current, toNotHaveTrait: trait)
            : manager.convert(current, toHaveTrait: trait)
        guard replacement.fontName != current.fontName else {
            statusMessage = bold ? "This font has no bold" : "This font has no italic"
            return
        }
        applyFontChange(replacement, to: annotation, message: bold ? "Bold toggled" : "Italic toggled")
    }

    private func applyFontChange(_ font: NSFont, to annotation: PDFAnnotation, message: String) {
        let oldFont = annotation.font
        let oldBounds = annotation.bounds
        let wasDirty = isDirty
        applyTextFont(font, to: annotation)
        let newBounds = annotation.bounds
        registerEdit(wasDirtyBefore: wasDirty, undo: { [weak self] in
            annotation.font = oldFont
            annotation.bounds = oldBounds
            self?.retainCoverBounds(for: annotation)
        }, redo: { [weak self] in
            annotation.font = font
            annotation.bounds = newBounds
            self?.retainCoverBounds(for: annotation)
        })
        synchronizeSelectedTextAppearance()
        changed(message)
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

    func retainCoverBounds(for annotation: PDFAnnotation) {
        retainCover(for: annotation)
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

    func forgetSignature() {
        savedSignature = []
        signatureImage = nil
        statusMessage = "Signature cleared"
    }

    func useDrawnSignature(_ strokes: [[CGPoint]]) {
        savedSignature = strokes
        signatureImage = nil
        activeTool = .signature
        pdfView?.needsDisplay = true
    }

    /// PDFKit reports matches as it finds them, one notification per hit, and one more
    /// when the sweep is over.
    private func observeSearch(in document: PDFDocument?) {
        for token in searchObservers { NotificationCenter.default.removeObserver(token) }
        searchObservers = []
        isSearching = false
        guard let document else { return }
        let center = NotificationCenter.default
        searchObservers.append(
            center.addObserver(forName: .PDFDocumentDidFindMatch, object: document, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let selection = notification.userInfo?["PDFDocumentFoundSelection"] as? PDFSelection else { return }
                    self?.collectSearchMatch(selection)
                }
            }
        )
        searchObservers.append(
            center.addObserver(forName: .PDFDocumentDidEndFind, object: document, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.finishSearch() }
            }
        )
    }

    var searchOptions: NSString.CompareOptions {
        var options: NSString.CompareOptions = []
        if !searchMatchesCase { options.insert(.caseInsensitive) }
        return options
    }

    /// Searching a long document takes long enough to freeze the window, so PDFKit runs it
    /// on its own and reports back as it goes.
    func updateSearch() {
        guard let document = pdfDocument else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        activeSearchQuery = query
        document.cancelFindString()
        searchResults = []
        searchSnippets = []
        searchMatchCounts = [:]
        searchIndex = 0
        pdfView?.clearSelection()
        guard !query.isEmpty else {
            isSearching = false
            statusMessage = "\(pageCount) pages"
            return
        }
        isSearching = true
        statusMessage = "Searching for \u{201C}\(query)\u{201D}…"
        document.beginFindString(query, withOptions: searchOptions)
    }

    private func rerunSearchIfNeeded() {
        guard !activeSearchQuery.isEmpty else { return }
        updateSearch()
    }

    /// Called for each match PDFKit turns up while a search runs. Matches arrive in
    /// document order, so counting them per page tells us which occurrence of the query
    /// this one is, which is what makes a whole-word test and a snippet possible: a
    /// PDFSelection knows its page and its rectangle, but not where it sits in the text.
    func collectSearchMatch(_ selection: PDFSelection) {
        guard let page = selection.pages.first else { return }
        let key = ObjectIdentifier(page)
        let occurrence = searchMatchCounts[key, default: 0]
        searchMatchCounts[key] = occurrence + 1
        let range = characterRange(ofOccurrence: occurrence, on: page)
        if searchWholeWords, let range, let text = page.string as NSString? {
            guard isWordBoundary(text, around: range) else { return }
        }
        searchResults.append(selection)
        searchSnippets.append(snippet(for: range, on: page, fallback: selection.string ?? ""))
        if searchResults.count == 1 {
            searchIndex = 0
            revealSearchResult(at: 0)
        }
    }

    func finishSearch() {
        isSearching = false
        statusMessage = searchResults.isEmpty
            ? "No results for \u{201C}\(activeSearchQuery)\u{201D}"
            : "\(searchResults.count) result\(searchResults.count == 1 ? "" : "s")"
    }

    private func characterRange(ofOccurrence occurrence: Int, on page: PDFPage) -> NSRange? {
        guard !activeSearchQuery.isEmpty, let pageText = page.string else { return nil }
        let text = pageText as NSString
        let options: NSString.CompareOptions = searchMatchesCase ? [] : [.caseInsensitive]
        var location = 0
        var seen = 0
        while location < text.length {
            let found = text.range(
                of: activeSearchQuery,
                options: options,
                range: NSRange(location: location, length: text.length - location)
            )
            guard found.location != NSNotFound else { return nil }
            if seen == occurrence { return found }
            seen += 1
            location = found.location + max(1, found.length)
        }
        return nil
    }

    private func isWordBoundary(_ text: NSString, around range: NSRange) -> Bool {
        func isLetter(at index: Int) -> Bool {
            guard index >= 0, index < text.length else { return false }
            let character = text.substring(with: NSRange(location: index, length: 1))
            guard let scalar = character.unicodeScalars.first else { return false }
            return CharacterSet.alphanumerics.contains(scalar)
        }
        return !isLetter(at: range.location - 1) && !isLetter(at: range.location + range.length)
    }

    /// A short piece of the page around a match, for the results list.
    private func snippet(for range: NSRange?, on page: PDFPage, fallback: String) -> String {
        guard let range, let pageText = page.string else { return fallback }
        let text = pageText as NSString
        let start = max(0, range.location - 32)
        let end = min(text.length, range.location + range.length + 32)
        var snippet = text.substring(with: NSRange(location: start, length: end - start))
        snippet = snippet.replacingOccurrences(of: "\n", with: " ")
        if start > 0 { snippet = "\u{2026}" + snippet }
        if end < text.length { snippet += "\u{2026}" }
        return snippet.trimmingCharacters(in: .whitespaces)
    }

    func searchSnippet(for selection: PDFSelection) -> String {
        guard let index = searchResults.firstIndex(of: selection), index < searchSnippets.count else {
            return selection.string ?? ""
        }
        return searchSnippets[index]
    }

    func pageNumber(for selection: PDFSelection) -> Int {
        guard let page = selection.pages.first, let document = pdfDocument else { return 0 }
        return document.index(for: page) + 1
    }

    func showSearchResult(_ selection: PDFSelection) {
        guard let index = searchResults.firstIndex(of: selection) else { return }
        searchIndex = index
        revealSearchResult(at: index)
    }

    func submitSearch(direction: Int) {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query == activeSearchQuery else {
            updateSearch()
            return
        }
        nextSearchResult(direction: direction)
    }

    func focusSearch() {
        sidebarVisible = true
        searchFocusRequest += 1
    }

    /// Blocks until the running search finishes, for tests and for anything that needs the
    /// full result set rather than the matches found so far.
    func waitForSearch(timeout: TimeInterval = 10) {
        let deadline = Date().addingTimeInterval(timeout)
        while isSearching, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
        }
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
        guard preferences.restoreLastDocument,
              let document = preferences.sessionDocuments.first else { return }
        restoreSessionDocument(document)
    }

    /// Puts back one of the things the app had open when it last quit.
    func restore(_ item: WorkspaceRegistry.RestoreItem) {
        didAttemptSessionRestore = true
        switch item {
        case .recovery:
            _ = restoreTemporaryRecoveryIfAvailable()
        case .session(let document):
            guard preferences.restoreLastDocument else { return }
            restoreSessionDocument(document)
        }
    }

    private func restoreSessionDocument(_ document: AppPreferences.SessionDocument) {
        let url = document.url
        guard FileManager.default.fileExists(atPath: url.path) else {
            preferences.forgetDocument(url)
            return
        }
        load(url, rememberSession: false)
        guard pdfDocument != nil, fileURL == url else { return }
        pageLayout = document.pageLayout
        currentPageIndex = max(0, min(document.pageIndex, pageCount - 1))
        pendingRestoredPageIndex = currentPageIndex
        pendingRestoredZoom = document.zoom > 0 ? document.zoom : nil
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
        if selectedPageIndexes.count <= 1 { selectedPageIndexes = [currentPageIndex] }
        rememberCurrentView()
    }

    func recordViewState(from view: PDFView) {
        guard !restoringViewState else { return }
        rememberCurrentView(zoom: Double(view.scaleFactor))
    }

    func refreshPreferenceAppearance() {
        pdfView?.refreshInteractionAppearance()
    }

    func setReadingMode(_ mode: ReadingMode) {
        preferences.readingMode = mode
        pdfView?.applyReadingMode(mode)
        statusMessage = "\(mode.label) reading mode"
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

    // MARK: - Stamping pages

    func beginPageStamp(_ options: PageStamper.Options) {
        stampOptions = options
        stampAppliesToSelectionOnly = selectedPageIndexes.count > 1
        showPageStamp = true
    }

    var stampTargetIndexes: [Int] {
        stampAppliesToSelectionOnly ? targetPageIndexes : Array(0..<pageCount)
    }

    /// A preview of what the stamp will look like on the first page it touches.
    func stampPreview(size: CGSize) -> NSImage? {
        guard let document = pdfDocument,
              let index = stampTargetIndexes.first,
              let page = document.page(at: index),
              let stamped = stampedPage(page, at: index, sequence: 0, in: document) else { return nil }
        let preview = PDFDocument()
        preview.insert(stamped, at: 0)
        return preview.page(at: 0)?.thumbnail(of: size, for: .cropBox)
    }

    private func stampedPage(_ page: PDFPage, at index: Int, sequence: Int, in document: PDFDocument) -> PDFPage? {
        let text = PageStamper.expand(
            stampOptions.text,
            pageIndex: index,
            pageCount: document.pageCount,
            documentName: displayName,
            sequence: sequence,
            options: stampOptions
        )
        return PageStamper.stamped(page, text: text, options: stampOptions)
    }

    /// Draws the stamp into each target page. The pages are rebuilt rather than annotated,
    /// so the result is part of the document straight away and survives any export.
    func applyPageStamp() {
        finishActiveTextEditing()
        guard let document = pdfDocument else { return }
        let indexes = stampTargetIndexes
        guard !indexes.isEmpty else { return }

        var replacements: [(index: Int, original: PDFPage, stamped: PDFPage)] = []
        for (sequence, index) in indexes.enumerated() {
            guard let page = document.page(at: index),
                  let stamped = stampedPage(page, at: index, sequence: sequence, in: document) else { continue }
            replacements.append((index, page, stamped))
        }
        guard !replacements.isEmpty else {
            presentError("The pages could not be stamped.")
            return
        }

        let wasDirty = isDirty
        let apply: ([(index: Int, original: PDFPage, stamped: PDFPage)], Bool) -> Void = { items, stamped in
            for item in items {
                guard item.index < document.pageCount else { continue }
                document.removePage(at: item.index)
                document.insert(stamped ? item.stamped : item.original, at: item.index)
            }
        }
        apply(replacements, true)
        let recorded = replacements
        registerEdit(
            wasDirtyBefore: wasDirty,
            undo: { apply(recorded, false) },
            redo: { apply(recorded, true) }
        )
        showPageStamp = false
        changed(replacements.count == 1 ? "1 page stamped" : "\(replacements.count) pages stamped")
    }

    /// Runs OCR over every page that has no text and rebuilds those pages with an
    /// invisible text layer, so the document becomes searchable everywhere it was a scan.
    func makeDocumentSearchable() {
        finishActiveTextEditing()
        guard let document = pdfDocument, !isRecognizingText else { return }
        let targets = OCRTextLayer.scannedPageIndexes(in: document)
        guard !targets.isEmpty else {
            statusMessage = "Every page already has searchable text"
            return
        }
        isRecognizingText = true
        statusMessage = "Recognizing text on \(targets.count) page\(targets.count == 1 ? "" : "s")…"

        Task { @MainActor in
            var replacements: [(index: Int, original: PDFPage, recognized: PDFPage)] = []
            for (position, index) in targets.enumerated() {
                guard let page = document.page(at: index),
                      let rendered = OCRTextLayer.render(page) else { continue }
                statusMessage = "Recognizing text on page \(index + 1) (\(position + 1) of \(targets.count))…"
                let image = rendered.image
                let lines = await Task.detached(priority: .userInitiated) {
                    OCRTextLayer.recognizedLines(in: image)
                }.value
                guard !lines.isEmpty,
                      let recognized = OCRTextLayer.searchablePage(
                        image: image,
                        pointSize: rendered.pointSize,
                        lines: lines
                      ) else { continue }
                replacements.append((index, page, recognized))
            }

            isRecognizingText = false
            guard !replacements.isEmpty else {
                statusMessage = "No text was recognized"
                return
            }
            let wasDirty = isDirty
            let apply: ([(index: Int, original: PDFPage, recognized: PDFPage)], Bool) -> Void = { items, searchable in
                for item in items {
                    guard item.index < document.pageCount else { continue }
                    document.removePage(at: item.index)
                    document.insert(searchable ? item.recognized : item.original, at: item.index)
                }
            }
            apply(replacements, true)
            let recorded = replacements
            registerEdit(
                wasDirtyBefore: wasDirty,
                undo: { apply(recorded, false) },
                redo: { apply(recorded, true) }
            )
            changed("\(replacements.count) page\(replacements.count == 1 ? "" : "s") made searchable")
        }
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

    /// Undo and redo run off this workspace's own history and nothing else. The window's
    /// undo manager collects operations the workspace knows nothing about — PDFKit's
    /// markup mode registers its own annotation edits there, and so does every text view
    /// in the window — and replaying those changed the document behind the workspace's
    /// back, or threw outright when a group was still open.
    func undo() {
        if pdfView?.undoTypingInInlineEditor() == true { return }
        guard let action = undoActions.popLast() else {
            statusMessage = "Nothing left to undo"
            return
        }
        action.undo()
        redoActions.append(action)
        isDirty = action.wasDirtyBefore
        finishHistoryChange("Change undone")
    }

    func redo() {
        if pdfView?.redoTypingInInlineEditor() == true { return }
        guard let action = redoActions.popLast() else {
            statusMessage = "Nothing left to redo"
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
        if let fileURL { preferences.forgetDocument(fileURL) }
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

    private func chooseSaveURL(defaultName: String, type: UTType = .pdf) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
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

extension NSImage {
    var pngData: Data? {
        guard let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }
}

/// One row of the sidebar's annotation list.
struct AnnotationEntry: Identifiable {
    let annotation: PDFAnnotation
    let pageIndex: Int

    var id: ObjectIdentifier { ObjectIdentifier(annotation) }

    var kind: String {
        if annotation.contents == RedactionFlattener.marker { return "Redaction" }
        if TextEditMarker.isTextEdit(annotation) { return "Replaced text" }
        switch annotation.type ?? "" {
        case "Highlight": return "Highlight"
        case "Underline": return "Underline"
        case "StrikeOut": return "Strike through"
        case "Text": return "Note"
        case "FreeText": return "Text"
        case "Ink": return "Drawing"
        case "Square": return "Rectangle"
        case "Circle": return "Ellipse"
        case "Stamp": return "Signature"
        default: return annotation.type ?? "Annotation"
        }
    }

    var summary: String {
        let contents = (annotation.contents ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !contents.isEmpty, contents != RedactionFlattener.marker else { return kind }
        return contents.replacingOccurrences(of: "\n", with: " ")
    }

    /// Who left it and when, when the annotation says so. Replaced text carries its pair
    /// identifier in the author field, so that one is never shown as a name.
    var attribution: String? {
        var parts: [String] = []
        if let author = annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !author.isEmpty, !TextEditMarker.isTextEdit(annotation) {
            parts.append(author)
        }
        if let date = annotation.modificationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .short
            formatter.timeStyle = .short
            parts.append(formatter.string(from: date))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var isEditable: Bool {
        annotation.isSubtype(.text) || annotation.isSubtype(.freeText)
    }

    var symbol: String {
        switch kind {
        case "Redaction": return "eye.slash"
        case "Replaced text": return "character.cursor.ibeam"
        case "Highlight": return "highlighter"
        case "Underline": return "underline"
        case "Strike through": return "strikethrough"
        case "Note": return "note.text"
        case "Text": return "textformat"
        case "Drawing": return "pencil.tip"
        case "Rectangle": return "rectangle"
        case "Ellipse": return "circle"
        case "Signature": return "signature"
        default: return "seal"
        }
    }
}

extension NSColor {
    /// A highlighter version of a color: the chosen hue at the chosen strength, falling
    /// back to yellow when the annotation color is black, which would blot out the text.
    func highlightTint(alpha: Double) -> NSColor {
        let base = usingColorSpace(.deviceRGB) ?? .systemYellow
        let isNeutral = base.saturationComponent < 0.15 && base.brightnessComponent < 0.35
        let tint = isNeutral ? NSColor.systemYellow : base
        return tint.withAlphaComponent(max(0.05, min(alpha, 1)))
    }
}

extension JSONEncoder {
    /// Stable, readable output, so exported form data diffs cleanly.
    static var sortedPretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
