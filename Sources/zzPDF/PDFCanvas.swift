import AppKit
import PDFKit
import SwiftUI

struct PDFCanvas: NSViewRepresentable {
    @EnvironmentObject var workspace: PDFWorkspace

    func makeNSView(context: Context) -> InteractivePDFView {
        let view = InteractivePDFView()
        view.workspace = workspace
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.pageShadowsEnabled = true
        view.backgroundColor = NSColor(calibratedWhite: 0.13, alpha: 1)
        view.interpolationQuality = .high
        workspace.attachPDFView(view)

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.pageChanged(_:)),
            name: .PDFViewPageChanged,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.annotationHit(_:)),
            name: .PDFViewAnnotationHit,
            object: view
        )
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.selectionChanged(_:)),
            name: .PDFViewSelectionChanged,
            object: view
        )
        for name in [Notification.Name.PDFViewVisiblePagesChanged, .PDFViewScaleChanged, .PDFViewDisplayModeChanged] {
            NotificationCenter.default.addObserver(
                context.coordinator,
                selector: #selector(Coordinator.appearanceChanged(_:)),
                name: name,
                object: view
            )
        }
        return view
    }

    func updateNSView(_ view: InteractivePDFView, context: Context) {
        if view.document !== workspace.pdfDocument {
            view.document = workspace.pdfDocument
            view.autoScales = true
        }
        view.workspace = workspace
        if view.displayMode != workspace.pageLayout.pdfMode {
            view.displayMode = workspace.pageLayout.pdfMode
            view.autoScales = true
        }
        workspace.applyPendingViewRestoration()
        view.refreshInteractionAppearance()
    }

    func makeCoordinator() -> Coordinator { Coordinator(workspace: workspace) }

    @MainActor
    final class Coordinator: NSObject {
        weak var workspace: PDFWorkspace?
        init(workspace: PDFWorkspace) { self.workspace = workspace }

        @objc func pageChanged(_ notification: Notification) {
            guard let workspace, let view = notification.object as? PDFView,
                  let page = view.currentPage, let document = view.document else { return }
            workspace.recordCurrentPage(document.index(for: page))
        }

        @objc func annotationHit(_ notification: Notification) {
            guard let workspace else { return }
            let annotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
            guard annotation?.isSubtype(.widget) != true else { return }
            workspace.selectAnnotation(annotation)
        }

        @objc func selectionChanged(_ notification: Notification) {
            guard let workspace, let view = notification.object as? PDFView else { return }
            let text = view.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            workspace.hasTextSelection = !text.isEmpty
        }

        @objc func appearanceChanged(_ notification: Notification) {
            guard let view = notification.object as? InteractivePDFView else { return }
            view.refreshInteractionAppearance()
            workspace?.recordViewState(from: view)
        }
    }
}

final class InteractivePDFView: PDFView, PDFPageOverlayViewProvider {
    private enum AnnotationDragMode: Equatable {
        case move
        case topLeft, topRight, bottomLeft, bottomRight
        case top, bottom, left, right
        /// A line or arrow is reshaped by its ends, not by a box around it.
        case lineStart, lineEnd
    }

    weak var workspace: PDFWorkspace?
    private var gesturePoints: [CGPoint] = []
    private weak var gesturePage: PDFPage?
    private var hoverPoint: CGPoint?
    private weak var hoverPage: PDFPage?
    private var pointerTrackingArea: NSTrackingArea?
    private weak var draggedAnnotation: PDFAnnotation?
    private weak var draggedAnnotationPage: PDFPage?
    private var annotationDragMode: AnnotationDragMode?
    private var annotationOriginalLine: (start: CGPoint, end: CGPoint)?
    private var annotationDragStart = CGPoint.zero
    private var annotationOriginalViewBounds = CGRect.zero
    private var annotationOriginalPageBounds = CGRect.zero
    private var annotationOriginalPaths: [NSBezierPath] = []
    private var annotationWasDirty = false
    private var annotationDidChange = false
    private var pageOverlays: [ObjectIdentifier: PDFPageFormOverlay] = [:]
    private var requestedEditor: (PDFAnnotation, PDFPage)?
    private var requestedInlineEditor: InlineEditorRequest?
    private var polygonPoints: [CGPoint] = []
    private weak var polygonPage: PDFPage?
    private var hoveredTextBounds: CGRect?
    private var hoveredTextPoint: CGPoint?
    private weak var hoveredTextPage: PDFPage?
    private lazy var drawingCursor: NSCursor = {
        let image = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { rect in
            let shaft = NSBezierPath()
            shaft.move(to: NSPoint(x: 12, y: 12))
            shaft.line(to: NSPoint(x: 21, y: 21))
            shaft.lineCapStyle = .round
            NSColor.white.withAlphaComponent(0.95).setStroke()
            shaft.lineWidth = 6
            shaft.stroke()
            NSColor.black.setStroke()
            shaft.lineWidth = 3.5
            shaft.stroke()

            let tip = NSBezierPath()
            tip.move(to: NSPoint(x: 12, y: 12))
            tip.line(to: NSPoint(x: 15.5, y: 13.2))
            tip.line(to: NSPoint(x: 13.2, y: 15.5))
            tip.close()
            NSColor.black.setFill()
            tip.fill()
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 12, y: 12))
    }()
    private lazy var highlighterCursor: NSCursor = {
        guard let symbol = NSImage(systemSymbolName: "highlighter", accessibilityDescription: "Highlight") else {
            return .crosshair
        }
        let image = symbol.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)) ?? symbol
        image.size = NSSize(width: 22, height: 22)
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 19))
    }()
    private lazy var underlineCursor = markupCursor(symbol: "underline", description: "Underline")
    private lazy var strikeOutCursor = markupCursor(symbol: "strikethrough", description: "Strike Through")
    private lazy var interactionOverlay: PDFInteractionOverlay = {
        let overlay = PDFInteractionOverlay(frame: bounds)
        overlay.owner = self
        overlay.autoresizingMask = [.width, .height]
        overlay.wantsLayer = true
        overlay.layer?.zPosition = 1_000
        return overlay
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(interactionOverlay, positioned: .above, relativeTo: nil)
        pageOverlayViewProvider = self
        isInMarkupMode = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(interactionOverlay, positioned: .above, relativeTo: nil)
        pageOverlayViewProvider = self
        isInMarkupMode = true
    }

    override func layout() {
        super.layout()
        interactionOverlay.frame = bounds
        interactionOverlay.needsDisplay = true
        for overlay in pageOverlays.values { overlay.refresh() }
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let tracking = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(tracking)
        pointerTrackingArea = tracking
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard workspace?.activeTool != .select, workspace?.activeTool != .fillForms else { return }
        let pageCursor = cursorForActiveTool
        for page in visiblePages {
            addCursorRect(convert(page.bounds(for: displayBox), from: page).standardized, cursor: pageCursor)
        }
    }

    override func cursorUpdate(with event: NSEvent) {
        cursor(at: convert(event.locationInWindow, from: nil)).set()
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if !polygonPoints.isEmpty {
            switch event.keyCode {
            case 53:                       // Escape abandons the shape being drawn
                cancelPolygon()
                return
            case 36, 76:                   // Return closes it
                finishPolygon(closed: true)
                return
            default:
                break
            }
        }
        if event.keyCode == 53, let workspace, workspace.activeTool != .select {
            workspace.activateSelectTool()
            return
        }
        super.keyDown(with: event)
    }

    private func finishPolygon(closed: Bool) {
        defer { cancelPolygon() }
        guard let workspace, let page = polygonPage, polygonPoints.count > 1 else { return }
        workspace.addPolygon(points: polygonPoints, on: page, closed: closed && polygonPoints.count > 2)
    }

    private func cancelPolygon() {
        polygonPoints.removeAll()
        polygonPage = nil
        interactionOverlay.needsDisplay = true
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false) {
            hoverPage = page
            hoverPoint = convert(viewPoint, to: page)
        } else {
            hoverPage = nil
            hoverPoint = nil
        }
        cursor(at: viewPoint).set()
        interactionOverlay.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverPage = nil
        hoverPoint = nil
        NSCursor.arrow.set()
        interactionOverlay.needsDisplay = true
    }

    fileprivate var cursorForActiveTool: NSCursor {
        guard let tool = workspace?.activeTool else { return .arrow }
        switch tool {
        case .select, .fillForms: return .arrow
        case .editText: return .iBeam
        case .highlight: return highlighterCursor
        case .underline: return underlineCursor
        case .strikeOut: return strikeOutCursor
        case .text: return .iBeam
        case .draw: return drawingCursor
        case .note, .line, .arrow, .polygon, .rectangle, .oval, .redact, .signature: return .crosshair
        }
    }

    private func markupCursor(symbol: String, description: String) -> NSCursor {
        guard let symbolImage = NSImage(systemSymbolName: symbol, accessibilityDescription: description) else {
            return .iBeam
        }
        let image = symbolImage.withSymbolConfiguration(.init(pointSize: 18, weight: .semibold)) ?? symbolImage
        image.size = NSSize(width: 22, height: 22)
        return NSCursor(image: image, hotSpot: NSPoint(x: 3, y: 19))
    }

    fileprivate func cursor(at point: CGPoint) -> NSCursor {
        guard page(for: point, nearest: false) != nil else { return .arrow }
        if NSEvent.modifierFlags.contains(.command), link(at: point) != nil { return .pointingHand }
        guard let workspace else { return cursorForActiveTool }
        if let selected = workspace.selectedAnnotation, let page = selected.page {
            if let mode = resizeHandle(at: point, for: selected, on: page) { return Self.cursor(for: mode) }
            if workspace.activeTool == .select || workspace.activeTool.drawsAnnotations,
               bodyContains(point, selected, on: page) {
                return .openHand
            }
        }
        // With Select in hand, anything that can be picked up says so.
        if workspace.activeTool == .select, let page = page(for: point, nearest: false),
           let hit = page.annotation(at: convert(point, to: page)), canReshape(hit) {
            return .openHand
        }
        return cursorForActiveTool
    }

    /// The link under `viewPoint`, if there is one there.
    func link(at viewPoint: CGPoint) -> PDFAnnotation? {
        guard let page = page(for: viewPoint, nearest: false) else { return nil }
        let pagePoint = convert(viewPoint, to: page)
        if let hit = page.annotation(at: pagePoint), hit.isSubtype(.link) { return hit }
        // A link often sits under the reader's own annotations, and those are what
        // annotation(at:) hands back.
        return page.annotations.first { $0.isSubtype(.link) && $0.bounds.contains(pagePoint) }
    }

    /// Holding Command over a link turns the pointer and says where the link goes, so it is
    /// clear the click will be taken as following it rather than as using the tool.
    override func flagsChanged(with event: NSEvent) {
        super.flagsChanged(with: event)
        guard let window, window.isKeyWindow else { return }
        let viewPoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(viewPoint) else { return }
        cursor(at: viewPoint).set()
        guard let workspace else { return }
        if event.modifierFlags.contains(.command),
           let link = link(at: viewPoint),
           let target = PDFLinkTarget.of(link) {
            workspace.statusMessage = "Click to open \(target.summary)"
        }
    }

    /// Tints the page for night or sepia reading.
    ///
    /// A filter needs the view to be layer-backed, and a layer-backed PDFView draws its
    /// text into that layer instead of straight to the screen, which softens every glyph.
    /// So normal reading leaves the view exactly as PDFKit wants it, and the tinted modes
    /// pin the layer to the screen's own scale rather than settling for a coarser one.
    func applyReadingMode(_ mode: ReadingMode) {
        backgroundColor = mode.backgroundColor
        let filters = mode.filters
        guard !filters.isEmpty else {
            // Not an empty array: any non-nil list of filters, even an empty one, puts the
            // layer on the filtered path, where the page is rasterized before it reaches
            // the screen and every glyph comes out soft.
            layer?.filters = nil
            return
        }
        wantsLayer = true
        layer?.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.filters = filters
    }

    func refreshInteractionAppearance() {
        if let mode = workspace?.preferences.readingMode { applyReadingMode(mode) }
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
        for overlay in pageOverlays.values { overlay.refresh() }
        interactionOverlay.needsDisplay = true
    }

    func cancelActiveInteraction() {
        polygonPoints.removeAll()
        polygonPage = nil
        gesturePoints.removeAll()
        gesturePage = nil
        hoverPoint = nil
        hoverPage = nil
        draggedAnnotation = nil
        draggedAnnotationPage = nil
        annotationDragMode = nil
        annotationDidChange = false
        annotationOriginalPaths.removeAll()
        refreshInteractionAppearance()
    }

    func beginInlineTextEditing(_ annotation: PDFAnnotation, on page: PDFPage) {
        let id = ObjectIdentifier(page)
        if let overlay = pageOverlays[id] {
            overlay.beginEditing(annotation)
        } else {
            requestedEditor = (annotation, page)
            layoutDocumentView()
        }
    }

    func beginInlineTextEditing(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        singleLine: Bool,
        seedText: String,
        frameBounds: CGRect
    ) {
        let request = InlineEditorRequest(
            annotation: annotation,
            page: page,
            singleLine: singleLine,
            seedText: seedText,
            frameBounds: frameBounds
        )
        if let overlay = pageOverlays[ObjectIdentifier(page)] {
            overlay.beginInlineEditing(request)
        } else {
            requestedInlineEditor = request
            layoutDocumentView()
        }
    }

    func cancelInlineTextEditing() {
        for overlay in pageOverlays.values { overlay.cancelCurrentEditor() }
        requestedEditor = nil
        requestedInlineEditor = nil
    }

    func commitInlineTextEditing() {
        requestedInlineEditor = nil
        for overlay in pageOverlays.values { overlay.commitInlineEditing() }
    }

    /// Moves form focus onto the next or previous page that has fields, scrolling to it.
    func focusFirstFormField(onPageAfter page: PDFPage?, direction: Int) -> Bool {
        guard let document, let page, direction != 0 else { return false }
        var index = document.index(for: page)
        guard index != NSNotFound else { return false }
        while true {
            index += direction > 0 ? 1 : -1
            guard index >= 0, index < document.pageCount, let next = document.page(at: index) else { return false }
            guard next.annotations.contains(where: { $0.isSubtype(.widget) }) else { continue }
            go(to: next)
            layoutDocumentView()
            guard let overlay = pageOverlays[ObjectIdentifier(next)] else { return false }
            overlay.refresh()
            return overlay.focusEdgeField(last: direction < 0)
        }
    }

    func detachInlineTextEditing() {
        requestedInlineEditor = nil
        for overlay in pageOverlays.values { overlay.detachInlineEditing() }
    }

    func undoTypingInInlineEditor() -> Bool {
        activeInlineEditor?.undoTyping() ?? false
    }

    func redoTypingInInlineEditor() -> Bool {
        activeInlineEditor?.redoTyping() ?? false
    }

    var activeInlineEditor: PDFInlineTextEditor? {
        pageOverlays.values.compactMap(\.inlineEditor).first
    }

    private func inlineEditorContains(_ viewPoint: CGPoint) -> Bool {
        guard let editor = activeInlineEditor, let container = editor.superview else { return false }
        return editor.frame.insetBy(dx: -4, dy: -4).contains(container.convert(viewPoint, from: self))
    }

    func pdfView(_ pdfView: PDFView, overlayViewFor page: PDFPage) -> NSView? {
        let overlay = PDFPageFormOverlay(owner: self, page: page)
        pageOverlays[ObjectIdentifier(page)] = overlay
        return overlay
    }

    func pdfView(_ pdfView: PDFView, willDisplayOverlayView overlayView: NSView, for page: PDFPage) {
        guard let overlay = overlayView as? PDFPageFormOverlay else { return }
        overlay.refresh()
        if let request = requestedEditor, request.1 === page {
            requestedEditor = nil
            overlay.beginEditing(request.0)
        }
        if let request = requestedInlineEditor, request.page === page {
            requestedInlineEditor = nil
            overlay.beginInlineEditing(request)
        }
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        pageOverlays.removeValue(forKey: ObjectIdentifier(page))
    }

    override func mouseDown(with event: NSEvent) {
        guard let workspace else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)

        // A click inside the open editor belongs to the text being typed. Taking first
        // responder here, as every other click does, would end that edit and start another
        // one, so the click is handed to the editor instead.
        if let editor = activeInlineEditor, inlineEditorContains(viewPoint) {
            editor.handleClick(event)
            return
        }

        // Command-click follows a link, whatever tool is in hand, so a reader does not have
        // to put the tool down or go through the context menu to use the document's links.
        if event.modifierFlags.contains(.command), let link = link(at: viewPoint) {
            window?.makeFirstResponder(self)
            workspace.followLink(link)
            return
        }

        window?.makeFirstResponder(self)

        if let selected = workspace.selectedAnnotation,
           let page = selected.page,
           let mode = resizeHandle(at: viewPoint, for: selected, on: page) {
            beginAnnotationDrag(selected, on: page, at: viewPoint, mode: mode)
            return
        }

        // The drawing just made stays in reach with the tool still in hand: grabbing it
        // moves it, where before the click started another drawing on top of it and moving
        // or reshaping meant going back to Select first.
        if workspace.activeTool.drawsAnnotations, polygonPoints.isEmpty,
           let selected = workspace.selectedAnnotation, let page = selected.page,
           bodyContains(viewPoint, selected, on: page) {
            beginAnnotationDrag(selected, on: page, at: viewPoint, mode: .move)
            return
        }

        if workspace.activeTool == .fillForms {
            workspace.selectAnnotation(nil)
            super.mouseDown(with: event)
            return
        }

        if workspace.activeTool == .editText {
            guard let page = page(for: viewPoint, nearest: false) else { return }
            let pagePoint = convert(viewPoint, to: page)
            if let annotation = page.annotation(at: pagePoint), !annotation.isSubtype(.widget) {
                if annotation.isSubtype(.freeText) {
                    workspace.beginInlineTextEditing(annotation)
                    return
                }
                if let text = workspace.textAnnotation(forCover: annotation) {
                    workspace.beginInlineTextEditing(text)
                    return
                }
            }
            workspace.selectAnnotation(nil)
            gesturePage = page
            gesturePoints = [pagePoint]
            interactionOverlay.needsDisplay = true
            return
        }

        if workspace.activeTool == .select {
            if let page = page(for: viewPoint, nearest: false) {
                let pagePoint = convert(viewPoint, to: page)
                if let annotation = widget(at: pagePoint, on: page) {
                    workspace.selectAnnotation(nil)
                    interactionOverlay.needsDisplay = true
                    if isEditableTextWidget(annotation) {
                        beginInlineTextEditing(annotation, on: page)
                        return
                    }
                    super.mouseDown(with: event)
                    return
                }
                if let hit = page.annotation(at: pagePoint) {
                    let annotation = workspace.textAnnotation(forCover: hit) ?? hit
                    workspace.selectAnnotation(annotation)
                    if event.clickCount == 2 {
                        if annotation.isSubtype(.text) {
                            workspace.beginEditingSelectedNote()
                        } else if annotation.isSubtype(.freeText) {
                            workspace.beginEditingFreeText(annotation)
                        }
                    }
                    beginAnnotationDrag(annotation, on: page, at: viewPoint, mode: nil)
                    return
                }
            }
            workspace.selectAnnotation(nil)
            interactionOverlay.needsDisplay = true
            super.mouseDown(with: event)
            return
        }

        if workspace.activeTool.markupKind != nil {
            workspace.selectAnnotation(nil)
            super.mouseDown(with: event)
            return
        }

        guard let page = page(for: viewPoint, nearest: false) else { return }

        if workspace.activeTool == .polygon {
            if polygonPage !== page { cancelPolygon() }
            polygonPage = page
            if event.clickCount > 1 {
                finishPolygon(closed: true)
                return
            }
            polygonPoints.append(convert(viewPoint, to: page))
            workspace.statusMessage = polygonPoints.count < 2
                ? "Click to add the next corner"
                : "Return closes the shape, double-click finishes it, Escape discards it"
            interactionOverlay.needsDisplay = true
            return
        }

        gesturePage = page
        gesturePoints = [convert(viewPoint, to: page)]
        if workspace.activeTool == .note || workspace.activeTool == .text || workspace.activeTool == .signature {
            workspace.addAnnotation(at: gesturePoints[0], on: page)
            gesturePoints.removeAll()
            gesturePage = nil
            interactionOverlay.needsDisplay = true
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let workspace else { return }
        if draggedAnnotation != nil {
            updateAnnotationDrag(to: convert(event.locationInWindow, from: nil), workspace: workspace)
            return
        }
        if workspace.activeTool.markupKind != nil {
            super.mouseDragged(with: event)
            return
        }
        guard workspace.activeTool != .select,
              let page = gesturePage else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        gesturePoints.append(convert(viewPoint, to: page))
        interactionOverlay.needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let workspace else { return }
        if draggedAnnotation != nil {
            finishAnnotationDrag(workspace: workspace)
            return
        }
        if let markupKind = workspace.activeTool.markupKind {
            super.mouseUp(with: event)
            DispatchQueue.main.async { [weak workspace] in workspace?.addMarkup(markupKind) }
            return
        }
        guard workspace.activeTool != .select,
              let page = gesturePage, let first = gesturePoints.first else {
            super.mouseUp(with: event)
            return
        }
        if workspace.activeTool == .editText {
            let last = convert(convert(event.locationInWindow, from: nil), to: page)
            let rect = CGRect(
                x: min(first.x, last.x), y: min(first.y, last.y),
                width: abs(last.x - first.x), height: abs(last.y - first.y)
            )
            gesturePoints.removeAll()
            gesturePage = nil
            interactionOverlay.needsDisplay = true
            if rect.width < 5 || rect.height < 5 {
                workspace.beginTextReplacement(at: first, on: page)
            } else {
                workspace.beginTextReplacement(in: rect, on: page)
            }
            return
        }
        if workspace.activeTool == .draw || workspace.activeTool.isLineTool ||
            workspace.activeTool == .rectangle ||
            workspace.activeTool == .oval || workspace.activeTool == .redact {
            let viewPoint = convert(event.locationInWindow, from: nil)
            gesturePoints.append(convert(viewPoint, to: page))
            workspace.addAnnotation(at: first, on: page, dragPoints: gesturePoints)
        }
        gesturePoints.removeAll()
        gesturePage = nil
        interactionOverlay.needsDisplay = true
    }

    private func finishAnnotationDrag(workspace: PDFWorkspace) {
        if annotationDidChange, let annotation = draggedAnnotation,
           annotationDragMode == .lineStart || annotationDragMode == .lineEnd,
           let original = annotationOriginalLine {
            workspace.registerLineChange(
                annotation,
                from: original,
                to: workspace.lineEndpoints(of: annotation),
                wasDirtyBefore: annotationWasDirty
            )
        } else if annotationDidChange, let annotation = draggedAnnotation {
            workspace.registerAnnotationGeometryChange(
                annotation,
                from: annotationOriginalPageBounds,
                oldPaths: annotationOriginalPaths,
                to: annotation.bounds,
                newPaths: copiedPaths(from: annotation),
                wasDirtyBefore: annotationWasDirty
            )
        }
        draggedAnnotation = nil
        draggedAnnotationPage = nil
        annotationDragMode = nil
        annotationOriginalLine = nil
        annotationDidChange = false
        annotationOriginalPaths.removeAll()
        interactionOverlay.needsDisplay = true
        if let window {
            cursor(at: convert(window.mouseLocationOutsideOfEventStream, from: nil)).set()
        }
    }

    private func widget(at point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        page.annotations.reversed().first {
            $0.isSubtype(.widget) && $0.bounds.insetBy(dx: -3, dy: -3).contains(point)
        }
    }

    func isEditableTextWidget(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.isSubtype(.widget), !annotation.isReadOnly else { return false }
        let fieldType = annotation.widgetFieldType
        return fieldType == .text || (fieldType != .button && fieldType != .choice && fieldType != .signature)
    }

    fileprivate func shouldCaptureInteraction(at viewPoint: CGPoint) -> Bool {
        guard let workspace else { return false }
        if inlineEditorContains(viewPoint) { return false }
        if workspace.activeTool == .fillForms { return false }
        if workspace.activeTool != .select { return true }
        if let selected = workspace.selectedAnnotation, let page = selected.page,
           resizeHandle(at: viewPoint, for: selected, on: page) != nil { return true }
        guard let page = page(for: viewPoint, nearest: false) else { return false }
        let pagePoint = convert(viewPoint, to: page)
        if widget(at: pagePoint, on: page) != nil { return false }
        guard let annotation = page.annotation(at: pagePoint) else { return false }
        return !annotation.isSubtype(.widget)
    }

    private func beginAnnotationDrag(
        _ annotation: PDFAnnotation,
        on page: PDFPage,
        at point: CGPoint,
        mode preferredMode: AnnotationDragMode?
    ) {
        let rect = convert(annotation.bounds, from: page).standardized
        annotationDragMode = preferredMode ?? resizeHandle(at: point, for: annotation, on: page) ?? .move
        annotationOriginalLine = annotation.isSubtype(.line) ? workspace?.lineEndpoints(of: annotation) : nil
        Self.cursor(for: annotationDragMode ?? .move).set()
        draggedAnnotation = annotation
        draggedAnnotationPage = page
        annotationDragStart = point
        annotationOriginalViewBounds = rect
        annotationOriginalPageBounds = annotation.bounds
        annotationOriginalPaths = copiedPaths(from: annotation)
        annotationWasDirty = workspace?.isDirty ?? false
        annotationDidChange = false
    }

    /// Whether an annotation can be moved and reshaped by hand. A note is an icon of a set
    /// size, and form fields and links belong to the document.
    private func canReshape(_ annotation: PDFAnnotation) -> Bool {
        !annotation.isSubtype(.widget) && !annotation.isSubtype(.link)
            && !annotation.isSubtype(.text) && !annotation.isSubtype(.popup)
    }

    /// The rectangle a selected annotation is outlined with, in view coordinates.
    private func handleRect(for annotation: PDFAnnotation, on page: PDFPage) -> CGRect {
        convert(annotation.bounds, from: page).standardized.insetBy(dx: -3, dy: -3)
    }

    /// A line's two ends, in view coordinates.
    private func lineEnds(of annotation: PDFAnnotation, on page: PDFPage) -> (start: CGPoint, end: CGPoint)? {
        guard let workspace else { return nil }
        let ends = workspace.lineEndpoints(of: annotation)
        return (convert(ends.start, from: page), convert(ends.end, from: page))
    }

    /// Which part of the selected annotation is under the pointer: a corner, an edge, or
    /// one end of a line. Corners and edges both reshape, so the whole outline is a handle
    /// and not just four dots on it.
    private func resizeHandle(at point: CGPoint, for annotation: PDFAnnotation, on page: PDFPage) -> AnnotationDragMode? {
        guard canReshape(annotation) else { return nil }
        if annotation.isSubtype(.line) {
            guard let ends = lineEnds(of: annotation, on: page) else { return nil }
            if hypot(ends.start.x - point.x, ends.start.y - point.y) <= 10 { return .lineStart }
            if hypot(ends.end.x - point.x, ends.end.y - point.y) <= 10 { return .lineEnd }
            return nil
        }
        let rect = handleRect(for: annotation, on: page)
        let corners: [(AnnotationDragMode, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY))
        ]
        if let corner = corners.first(where: { hypot($0.1.x - point.x, $0.1.y - point.y) <= 10 }) {
            return corner.0
        }
        let reach: CGFloat = 5
        let alongX = point.x >= rect.minX && point.x <= rect.maxX
        let alongY = point.y >= rect.minY && point.y <= rect.maxY
        if alongY, abs(point.x - rect.minX) <= reach { return .left }
        if alongY, abs(point.x - rect.maxX) <= reach { return .right }
        if alongX, abs(point.y - rect.maxY) <= reach { return .top }
        if alongX, abs(point.y - rect.minY) <= reach { return .bottom }
        return nil
    }

    /// Whether `point` is on the annotation itself rather than beside it. A line counts
    /// along its length, not over the empty box around it.
    private func bodyContains(_ point: CGPoint, _ annotation: PDFAnnotation, on page: PDFPage) -> Bool {
        guard canReshape(annotation) else { return false }
        if annotation.isSubtype(.line) {
            guard let ends = lineEnds(of: annotation, on: page) else { return false }
            let width = max(6, (annotation.border?.lineWidth ?? 1) * scaleFactor / 2 + 4)
            return distance(from: point, toSegment: ends.start, ends.end) <= width
        }
        return handleRect(for: annotation, on: page).contains(point)
    }

    private func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - a.x, point.y - a.y) }
        let t = max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared))
        return hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy))
    }

    /// The pointer for a part of an annotation, so the reader can see what dragging there
    /// will do before they press.
    private static func cursor(for mode: AnnotationDragMode) -> NSCursor {
        if #available(macOS 15.0, *) {
            switch mode {
            case .move: return .closedHand
            case .topLeft: return .frameResize(position: .topLeft, directions: .all)
            case .topRight: return .frameResize(position: .topRight, directions: .all)
            case .bottomLeft: return .frameResize(position: .bottomLeft, directions: .all)
            case .bottomRight: return .frameResize(position: .bottomRight, directions: .all)
            case .top: return .frameResize(position: .top, directions: .all)
            case .bottom: return .frameResize(position: .bottom, directions: .all)
            case .left: return .frameResize(position: .left, directions: .all)
            case .right: return .frameResize(position: .right, directions: .all)
            case .lineStart, .lineEnd: return .crosshair
            }
        }
        // macOS 14 has no diagonal resize pointers; the crosshair is the nearest it has.
        switch mode {
        case .move: return .closedHand
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight, .lineStart, .lineEnd: return .crosshair
        }
    }

    private func updateAnnotationDrag(to point: CGPoint, workspace: PDFWorkspace) {
        guard let annotation = draggedAnnotation, let page = draggedAnnotationPage,
              let mode = annotationDragMode else { return }
        let delta = CGPoint(x: point.x - annotationDragStart.x, y: point.y - annotationDragStart.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }

        if mode == .lineStart || mode == .lineEnd, let original = annotationOriginalLine {
            let pointer = convert(point, to: page)
            let start = mode == .lineStart ? pointer : original.start
            let end = mode == .lineEnd ? pointer : original.end
            guard hypot(end.x - start.x, end.y - start.y) > 3 else { return }
            workspace.setLineEndpoints(annotation, start: start, end: end)
            annotationsChanged(on: page)
            needsDisplay = true
            annotationDidChange = true
            workspace.changed("Line reshaped")
            interactionOverlay.needsDisplay = true
            return
        }

        var rect = annotationOriginalViewBounds
        switch mode {
        case .lineStart, .lineEnd:
            return
        case .move:
            rect = rect.offsetBy(dx: delta.x, dy: delta.y)
        case .top:
            rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height + delta.y)
        case .bottom:
            rect = CGRect(x: rect.minX, y: rect.minY + delta.y, width: rect.width, height: rect.height - delta.y)
        case .left:
            rect = CGRect(x: rect.minX + delta.x, y: rect.minY, width: rect.width - delta.x, height: rect.height)
        case .right:
            rect = CGRect(x: rect.minX, y: rect.minY, width: rect.width + delta.x, height: rect.height)
        case .topLeft:
            rect = CGRect(x: rect.minX + delta.x, y: rect.minY,
                          width: rect.width - delta.x, height: rect.height + delta.y)
        case .topRight:
            rect = CGRect(x: rect.minX, y: rect.minY,
                          width: rect.width + delta.x, height: rect.height + delta.y)
        case .bottomLeft:
            rect = CGRect(x: rect.minX + delta.x, y: rect.minY + delta.y,
                          width: rect.width - delta.x, height: rect.height - delta.y)
        case .bottomRight:
            rect = CGRect(x: rect.minX, y: rect.minY + delta.y,
                          width: rect.width + delta.x, height: rect.height - delta.y)
        }
        rect = rect.standardized
        guard rect.width >= 10, rect.height >= 10 else { return }
        let newBounds = convert(rect, to: page).standardized
        if mode != .move, let scalableInk = annotation as? ScalableInkAnnotation {
            scalableInk.resize(to: newBounds)
        } else if mode != .move, annotation.isSubtype(.ink) {
            replacePaths(on: annotation, with: scaledPaths(annotationOriginalPaths, from: annotationOriginalPageBounds, to: newBounds))
            annotation.bounds = newBounds
        } else {
            annotation.bounds = newBounds
        }
        workspace.synchronizeCover(for: annotation)
        annotationsChanged(on: page)
        needsDisplay = true
        annotationDidChange = true
        workspace.changed(mode == .move ? "Annotation moved" : "Annotation resized")
        interactionOverlay.needsDisplay = true
    }

    fileprivate func drawInteractionOverlay() {
        guard let workspace else { return }

        if let annotation = workspace.selectedAnnotation, let page = annotation.page {
            func drawHandle(at point: CGPoint) {
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                NSColor.white.setFill()
                handle.fill()
                NSColor.controlAccentColor.setStroke()
                handle.lineWidth = 1.5
                handle.stroke()
            }
            if annotation.isSubtype(.line), let ends = lineEnds(of: annotation, on: page) {
                // A line is reshaped by its ends, so those are its handles; the padded box
                // around it is nothing the reader drew and is left out.
                drawHandle(at: ends.start)
                drawHandle(at: ends.end)
            } else {
                let rect = handleRect(for: annotation, on: page)
                let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
                outline.lineWidth = 2
                outline.setLineDash([6, 3], count: 2, phase: 0)
                NSColor.controlAccentColor.setStroke()
                outline.stroke()
                if canReshape(annotation) {
                    for point in [
                        CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                        CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY),
                        CGPoint(x: rect.midX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY),
                        CGPoint(x: rect.minX, y: rect.midY), CGPoint(x: rect.maxX, y: rect.midY)
                    ] {
                        drawHandle(at: point)
                    }
                }
            }
        }

        if workspace.activeTool == .editText, gesturePage == nil,
           let page = hoverPage, let point = hoverPoint,
           let bounds = editableTextBounds(at: point, on: page) {
            let rect = convert(bounds, from: page).standardized.insetBy(dx: -2, dy: -2)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            outline.lineWidth = 1.5
            outline.setLineDash([4, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            outline.fill()
            NSColor.controlAccentColor.withAlphaComponent(0.9).setStroke()
            outline.stroke()
        }

        if let page = polygonPage, !polygonPoints.isEmpty {
            drawPolygonPreview(on: page, workspace: workspace)
        }

        if let page = gesturePage, gesturePoints.count > 1 {
            drawGesturePreview(on: page, workspace: workspace)
        }

        if workspace.activeTool == .signature, workspace.hasSignature,
           let page = hoverPage, let point = hoverPoint {
            drawSignaturePreview(at: point, on: page, workspace: workspace)
        }
    }

    private func drawGesturePreview(on page: PDFPage, workspace: PDFWorkspace) {
        let viewPoints = gesturePoints.map { convert($0, from: page) }
        guard let first = viewPoints.first, let last = viewPoints.last else { return }
        let color = workspace.nsAnnotationColor

        if workspace.activeTool.isLineTool {
            drawLinePreview(from: first, to: last, color: color, arrow: workspace.activeTool == .arrow, width: workspace.lineWidth)
            return
        }

        if workspace.activeTool == .draw {
            let path = NSBezierPath()
            path.move(to: first)
            for point in viewPoints.dropFirst() { path.line(to: point) }
            path.lineWidth = workspace.lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            color.setStroke()
            path.stroke()
            return
        }

        let rect = CGRect(x: min(first.x, last.x), y: min(first.y, last.y),
                          width: abs(last.x - first.x), height: abs(last.y - first.y))
        if workspace.activeTool == .editText {
            let selection = NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2)
            selection.lineWidth = 1.5
            selection.setLineDash([5, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
            selection.fill()
            NSColor.controlAccentColor.setStroke()
            selection.stroke()
            return
        }
        let path = workspace.activeTool == .oval ? NSBezierPath(ovalIn: rect) : NSBezierPath(rect: rect)
        if workspace.activeTool == .redact {
            path.lineWidth = max(workspace.lineWidth * scaleFactor, 1.5)
            path.setLineDash([7, 4], count: 2, phase: 0)
            NSColor.black.withAlphaComponent(0.62).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
        } else {
            path.lineWidth = max(workspace.lineWidth * scaleFactor, 0.5)
            if workspace.shapeHasFill {
                NSColor(workspace.shapeFillColor).setFill()
                path.fill()
            }
            color.setStroke()
        }
        path.stroke()
    }

    private func drawLinePreview(from start: CGPoint, to end: CGPoint, color: NSColor, arrow: Bool, width: Double) {
        let path = NSBezierPath()
        path.move(to: start)
        path.line(to: end)
        path.lineWidth = max(width * scaleFactor, 1)
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
        guard arrow else { return }
        let angle = atan2(end.y - start.y, end.x - start.x)
        let size = max(9, width * 3.4 * scaleFactor)
        let head = NSBezierPath()
        head.move(to: end)
        head.line(to: CGPoint(x: end.x - size * cos(angle - .pi / 7), y: end.y - size * sin(angle - .pi / 7)))
        head.line(to: CGPoint(x: end.x - size * cos(angle + .pi / 7), y: end.y - size * sin(angle + .pi / 7)))
        head.close()
        color.setFill()
        head.fill()
    }

    private func drawPolygonPreview(on page: PDFPage, workspace: PDFWorkspace) {
        let viewPoints = polygonPoints.map { convert($0, from: page) }
        guard let first = viewPoints.first else { return }
        let path = NSBezierPath()
        path.move(to: first)
        for point in viewPoints.dropFirst() { path.line(to: point) }
        if let hoverPoint, hoverPage === page {
            path.line(to: convert(hoverPoint, from: page))
        }
        path.lineWidth = max(workspace.lineWidth * scaleFactor, 1)
        path.lineJoinStyle = .round
        workspace.nsAnnotationColor.setStroke()
        path.stroke()

        for point in viewPoints {
            let dot = NSBezierPath(ovalIn: CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6))
            NSColor.white.setFill()
            dot.fill()
            NSColor.controlAccentColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
    }

    private func editableTextBounds(at point: CGPoint, on page: PDFPage) -> CGRect? {
        if let cached = hoveredTextBounds, hoveredTextPage === page,
           cached.insetBy(dx: -2, dy: -2).contains(point) {
            return cached
        }
        if let last = hoveredTextPoint, hoveredTextPage === page, hoveredTextBounds == nil,
           hypot(last.x - point.x, last.y - point.y) < 5 {
            return nil
        }
        hoveredTextPage = page
        hoveredTextPoint = point
        if let annotation = page.annotation(at: point), !annotation.isSubtype(.widget) {
            hoveredTextBounds = annotation.bounds
            return hoveredTextBounds
        }
        hoveredTextBounds = workspace?.replaceableTextBounds(at: point, on: page)
        return hoveredTextBounds
    }

    private func drawSignaturePreview(at point: CGPoint, on page: PDFPage, workspace: PDFWorkspace) {
        let pageBounds = workspace.signatureBounds(at: point)
        let viewBounds = convert(pageBounds, from: page).standardized
        if let image = workspace.signatureImage {
            image.draw(in: viewBounds, from: .zero, operation: .sourceOver, fraction: 0.58, respectFlipped: true, hints: nil)
        } else {
            for stroke in workspace.savedSignature where stroke.count > 1 {
                let path = NSBezierPath()
                let firstPagePoint = CGPoint(
                    x: pageBounds.minX + stroke[0].x * pageBounds.width,
                    y: pageBounds.minY + (1 - stroke[0].y) * pageBounds.height
                )
                path.move(to: convert(firstPagePoint, from: page))
                for point in stroke.dropFirst() {
                    let pagePoint = CGPoint(
                        x: pageBounds.minX + point.x * pageBounds.width,
                        y: pageBounds.minY + (1 - point.y) * pageBounds.height
                    )
                    path.line(to: convert(pagePoint, from: page))
                }
                path.lineWidth = workspace.lineWidth
                path.lineCapStyle = .round
                path.lineJoinStyle = .round
                workspace.nsAnnotationColor.withAlphaComponent(0.62).setStroke()
                path.stroke()
            }
        }
        let border = NSBezierPath(roundedRect: viewBounds.insetBy(dx: -3, dy: -3), xRadius: 3, yRadius: 3)
        border.setLineDash([5, 4], count: 2, phase: 0)
        NSColor.controlAccentColor.withAlphaComponent(0.75).setStroke()
        border.stroke()
    }
}

private func copiedPaths(from annotation: PDFAnnotation) -> [NSBezierPath] {
    (annotation.paths ?? []).compactMap { $0.copy() as? NSBezierPath }
}

private func replacePaths(on annotation: PDFAnnotation, with paths: [NSBezierPath]) {
    for path in annotation.paths ?? [] { annotation.remove(path) }
    for path in paths { annotation.add(path) }
}

private func scaledPaths(_ paths: [NSBezierPath], from oldBounds: CGRect, to newBounds: CGRect) -> [NSBezierPath] {
    guard oldBounds.width > 0, oldBounds.height > 0 else { return paths }
    let scaleX = newBounds.width / oldBounds.width
    let scaleY = newBounds.height / oldBounds.height
    return paths.compactMap { source in
        guard let path = source.copy() as? NSBezierPath else { return nil }
        var transform = AffineTransform.identity
        transform.scale(x: scaleX, y: scaleY)
        path.transform(using: transform)
        return path
    }
}

final class PDFInteractionOverlay: NSView {
    weak var owner: InteractivePDFView?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let owner else { return nil }
        let ownerPoint = owner.convert(point, from: self)
        return owner.shouldCaptureInteraction(at: ownerPoint) ? self : nil
    }
    override func cursorUpdate(with event: NSEvent) {
        guard let owner else { return }
        owner.cursor(at: owner.convert(event.locationInWindow, from: nil)).set()
    }
    override func mouseMoved(with event: NSEvent) { owner?.mouseMoved(with: event) }
    override func mouseExited(with event: NSEvent) { owner?.mouseExited(with: event) }
    override func mouseDown(with event: NSEvent) { owner?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { owner?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { owner?.mouseUp(with: event) }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        owner?.drawInteractionOverlay()
    }
}

final class NoteMarkerAnnotation: PDFAnnotation {
    init(bounds: CGRect) {
        super.init(bounds: bounds, forType: .text, withProperties: nil)
        color = .systemYellow
        iconType = .comment
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        context.saveGState()
        let body = bounds.insetBy(dx: 2.5, dy: 4.5).offsetBy(dx: 0, dy: 2)
        let bubble = CGPath(roundedRect: body, cornerWidth: 6, cornerHeight: 6, transform: nil)
        context.addPath(bubble)
        context.setFillColor(NSColor.systemYellow.cgColor)
        context.fillPath()

        let tail = CGMutablePath()
        tail.move(to: CGPoint(x: body.minX + 6, y: body.minY + 1))
        tail.addLine(to: CGPoint(x: body.minX + 3, y: bounds.minY + 2))
        tail.addLine(to: CGPoint(x: body.minX + 11, y: body.minY + 1))
        tail.closeSubpath()
        context.addPath(tail)
        context.fillPath()

        context.setFillColor(NSColor.black.withAlphaComponent(0.62).cgColor)
        let dotY = body.midY - 1.25
        for dotX in [body.midX - 6, body.midX, body.midX + 6] {
            context.fillEllipse(in: CGRect(x: dotX - 1.4, y: dotY - 1.4, width: 2.8, height: 2.8))
        }
        context.restoreGState()
    }
}

final class ImageStampAnnotation: PDFAnnotation {
    private var stampImage: NSImage

    init(bounds: CGRect, image: NSImage) {
        self.stampImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        color = .clear
        contents = "Graphic signature"
    }

    required init?(coder: NSCoder) {
        guard let data = coder.decodeObject(forKey: "zzPDFStampImage") as? Data,
              let image = NSImage(data: data) else { return nil }
        stampImage = image
        super.init(coder: coder)
    }

    override func encode(with coder: NSCoder) {
        if let data = stampImage.tiffRepresentation {
            coder.encode(data, forKey: "zzPDFStampImage")
        }
        super.encode(with: coder)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cgImage = stampImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cgImage, in: bounds)
        context.restoreGState()
    }
}
