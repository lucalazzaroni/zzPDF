import AppKit
import PDFKit
import SwiftUI
@preconcurrency import Vision

enum CanvasTool: String, CaseIterable, Identifiable {
    case select, note, text, draw, rectangle, oval, redact, signature

    var id: String { rawValue }
    var label: String {
        switch self {
        case .select: "Seleziona"
        case .note: "Nota"
        case .text: "Testo"
        case .draw: "Disegna"
        case .rectangle: "Rettangolo"
        case .oval: "Ellisse"
        case .redact: "Oscura"
        case .signature: "Firma"
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

@MainActor
final class PDFWorkspace: ObservableObject {
    @Published var pdfDocument: PDFDocument?
    @Published var fileURL: URL?
    @Published var currentPageIndex = 0
    @Published var selectedAnnotation: PDFAnnotation?
    @Published var activeTool: CanvasTool = .select
    @Published var annotationColor: Color = .yellow
    @Published var lineWidth: Double = 2.5
    @Published var textToInsert = "Testo"
    @Published var noteText = "Nota"
    @Published var searchText = ""
    @Published var searchResults: [PDFSelection] = []
    @Published var searchIndex = 0
    @Published var sidebarVisible = true
    @Published var inspectorVisible = true
    @Published var showSignaturePad = false
    @Published var showPasswordExport = false
    @Published var showOCRResult = false
    @Published var ocrText = ""
    @Published var statusMessage = "Apri un PDF per iniziare"
    @Published var isDirty = false
    @Published var savedSignature: [[CGPoint]] = []

    weak var pdfView: InteractivePDFView?

    var hasDocument: Bool { pdfDocument != nil }
    var pageCount: Int { pdfDocument?.pageCount ?? 0 }
    var displayName: String { fileURL?.deletingPathExtension().lastPathComponent ?? "Senza titolo" }
    var nsAnnotationColor: NSColor { NSColor(annotationColor) }

    func openDocument() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.message = "Scegli un documento PDF"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    func load(_ url: URL) {
        guard let document = PDFDocument(url: url) else {
            presentError("Il documento non può essere aperto.")
            return
        }
        if document.isLocked {
            let password = requestPassword(title: "PDF protetto", message: "Inserisci la password per aprire il documento.")
            guard let password, document.unlock(withPassword: password) else {
                presentError("Password non valida.")
                return
            }
        }
        pdfDocument = document
        fileURL = url
        currentPageIndex = 0
        isDirty = false
        searchResults = []
        statusMessage = "\(document.pageCount) pagine"
    }

    func save() {
        guard let document = pdfDocument else { return }
        guard let url = fileURL else { saveAs(); return }
        if document.write(to: url) {
            isDirty = false
            statusMessage = "Salvato"
        } else {
            presentError("Non è stato possibile salvare il documento.")
        }
    }

    func saveAs() {
        guard let document = pdfDocument, let url = chooseSaveURL(defaultName: "\(displayName).pdf") else { return }
        if document.write(to: url) {
            fileURL = url
            isDirty = false
            statusMessage = "Copia salvata"
        } else {
            presentError("Non è stato possibile salvare il documento.")
        }
    }

    func exportFlattened() {
        guard let document = pdfDocument,
              let url = chooseSaveURL(defaultName: "\(displayName)-appiattito.pdf") else { return }
        let options: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
            .saveImagesAsJPEGOption: true,
            .optimizeImagesForScreenOption: true
        ]
        if document.write(to: url, withOptions: options) {
            statusMessage = "Copia appiattita esportata"
        } else {
            presentError("Esportazione non riuscita.")
        }
    }

    func exportProtected(ownerPassword: String, userPassword: String, flatten: Bool) {
        guard let document = pdfDocument,
              !ownerPassword.isEmpty,
              let url = chooseSaveURL(defaultName: "\(displayName)-protetto.pdf") else { return }
        var options: [PDFDocumentWriteOption: Any] = [.ownerPasswordOption: ownerPassword]
        if !userPassword.isEmpty { options[.userPasswordOption] = userPassword }
        if flatten { options[.burnInAnnotationsOption] = true }
        if document.write(to: url, withOptions: options) {
            statusMessage = "PDF protetto esportato"
            showPasswordExport = false
        } else {
            presentError("Non è stato possibile proteggere il PDF.")
        }
    }

    func mergePDF() {
        guard let document = pdfDocument else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.message = "I documenti verranno aggiunti dopo la pagina corrente"
        guard panel.runModal() == .OK else { return }
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
        changed("PDF uniti")
    }

    func importImages() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .tiff, .heic]
        panel.allowsMultipleSelection = true
        panel.message = "Ogni immagine diventerà una pagina"
        guard panel.runModal() == .OK else { return }
        let destination = pdfDocument ?? PDFDocument()
        for url in panel.urls {
            if let image = NSImage(contentsOf: url), let page = PDFPage(image: image) {
                destination.insert(page, at: destination.pageCount)
            }
        }
        if destination.pageCount > 0 {
            pdfDocument = destination
            fileURL = nil
            changed("Immagini importate")
        }
    }

    func extractCurrentPage() {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex)?.copy() as? PDFPage,
              let url = chooseSaveURL(defaultName: "Pagina-\(currentPageIndex + 1).pdf") else { return }
        let output = PDFDocument()
        output.insert(page, at: 0)
        if output.write(to: url) { statusMessage = "Pagina estratta" }
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
        document.removePage(at: currentPageIndex)
        document.insert(page, at: target)
        currentPageIndex = target
        changed("Pagina spostata")
        selectPage(target)
    }

    func duplicateCurrentPage() {
        guard let document = pdfDocument,
              let page = document.page(at: currentPageIndex)?.copy() as? PDFPage else { return }
        document.insert(page, at: currentPageIndex + 1)
        changed("Pagina duplicata")
        selectPage(currentPageIndex + 1)
    }

    func deleteCurrentPage() {
        guard let document = pdfDocument, document.pageCount > 0 else { return }
        document.removePage(at: currentPageIndex)
        currentPageIndex = max(0, min(currentPageIndex, document.pageCount - 1))
        changed("Pagina eliminata")
        if document.pageCount > 0 { selectPage(currentPageIndex) }
    }

    func rotateCurrentPage(by degrees: Int) {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        page.rotation = (page.rotation + degrees + 360) % 360
        changed("Pagina ruotata")
    }

    func addMarkup(_ kind: MarkupKind) {
        guard let selection = pdfView?.currentSelection else {
            statusMessage = "Seleziona prima del testo nel documento"
            return
        }
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
        changed("Annotazione aggiunta")
    }

    func addAnnotation(at point: CGPoint, on page: PDFPage, dragPoints: [CGPoint] = []) {
        let color = nsAnnotationColor
        let annotation: PDFAnnotation?
        switch activeTool {
        case .select:
            return
        case .note:
            let item = PDFAnnotation(bounds: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24), forType: .text, withProperties: nil)
            item.contents = noteText
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
            let item = PDFAnnotation(bounds: rect, forType: activeTool == .rectangle ? .square : .circle, withProperties: nil)
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
            item.contents = "Oscuramento — esportare appiattito"
            let border = PDFBorder()
            border.lineWidth = 0
            item.border = border
            annotation = item
        case .draw:
            annotation = makeInkAnnotation(points: dragPoints, color: color, width: lineWidth)
        case .signature:
            guard !savedSignature.isEmpty else {
                showSignaturePad = true
                return
            }
            annotation = makeSignatureAnnotation(at: point, color: color)
        }
        if let annotation {
            page.addAnnotation(annotation)
            selectedAnnotation = annotation
            changed("Annotazione aggiunta")
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

    private func makeSignatureAnnotation(at point: CGPoint, color: NSColor) -> PDFAnnotation? {
        let width: CGFloat = 180
        let height: CGFloat = 70
        let bounds = CGRect(x: point.x, y: point.y - height, width: width, height: height)
        let item = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        item.color = color
        let border = PDFBorder()
        border.lineWidth = lineWidth
        item.border = border
        for stroke in savedSignature where stroke.count > 1 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x * width, y: (1 - stroke[0].y) * height))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x * width, y: (1 - point.y) * height))
            }
            item.add(path)
        }
        return item
    }

    func removeSelectedAnnotation() {
        guard let annotation = selectedAnnotation, let page = annotation.page else { return }
        page.removeAnnotation(annotation)
        selectedAnnotation = nil
        changed("Annotazione rimossa")
    }

    func updateSearch() {
        guard let document = pdfDocument else { return }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        searchResults = query.isEmpty ? [] : document.findString(query, withOptions: .caseInsensitive)
        searchIndex = 0
        if let first = searchResults.first { pdfView?.setCurrentSelection(first, animate: true) }
        statusMessage = query.isEmpty ? "\(pageCount) pagine" : "\(searchResults.count) risultati"
    }

    func nextSearchResult(direction: Int) {
        guard !searchResults.isEmpty else { return }
        searchIndex = (searchIndex + direction + searchResults.count) % searchResults.count
        pdfView?.setCurrentSelection(searchResults[searchIndex], animate: true)
    }

    func fitPage() { pdfView?.autoScales = true }
    func actualSize() { pdfView?.scaleFactor = 1.0 }
    func zoom(by factor: CGFloat) { pdfView?.scaleFactor = max(0.25, min((pdfView?.scaleFactor ?? 1) * factor, 5)) }

    func recognizeCurrentPage() {
        guard let page = pdfDocument?.page(at: currentPageIndex) else { return }
        statusMessage = "Riconoscimento testo…"
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
                self.statusMessage = text.isEmpty ? "Nessun testo riconosciuto" : "Testo riconosciuto"
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
        page.setBounds(bounds, for: box)
        changed("Margini pagina modificati")
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
        alert.addButton(withTitle: "Continua")
        alert.addButton(withTitle: "Annulla")
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
