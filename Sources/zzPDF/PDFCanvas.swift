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
        workspace.pdfView = view

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
            workspace.currentPageIndex = document.index(for: page)
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
            (notification.object as? InteractivePDFView)?.refreshInteractionAppearance()
        }
    }
}

final class InteractivePDFView: PDFView, PDFPageOverlayViewProvider {
    private enum AnnotationDragMode: Equatable { case move, topLeft, topRight, bottomLeft, bottomRight }

    weak var workspace: PDFWorkspace?
    private var gesturePoints: [CGPoint] = []
    private weak var gesturePage: PDFPage?
    private var hoverPoint: CGPoint?
    private weak var hoverPage: PDFPage?
    private var pointerTrackingArea: NSTrackingArea?
    private weak var draggedAnnotation: PDFAnnotation?
    private weak var draggedAnnotationPage: PDFPage?
    private var annotationDragMode: AnnotationDragMode?
    private var annotationDragStart = CGPoint.zero
    private var annotationOriginalViewBounds = CGRect.zero
    private var annotationOriginalPageBounds = CGRect.zero
    private var annotationOriginalPaths: [NSBezierPath] = []
    private var annotationWasDirty = false
    private var annotationDidChange = false
    private var pageOverlays: [ObjectIdentifier: PDFPageFormOverlay] = [:]
    private var requestedEditor: (PDFAnnotation, PDFPage)?
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
        if event.keyCode == 53, let workspace, workspace.activeTool != .select {
            workspace.activateSelectTool()
            return
        }
        super.keyDown(with: event)
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
        case .highlight: return highlighterCursor
        case .underline: return underlineCursor
        case .strikeOut: return strikeOutCursor
        case .text: return .iBeam
        case .draw: return drawingCursor
        case .note, .rectangle, .oval, .redact, .signature: return .crosshair
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
        return cursorForActiveTool
    }

    func refreshInteractionAppearance() {
        window?.acceptsMouseMovedEvents = true
        window?.invalidateCursorRects(for: self)
        for overlay in pageOverlays.values { overlay.refresh() }
        interactionOverlay.needsDisplay = true
    }

    func cancelActiveInteraction() {
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

    func cancelInlineTextEditing() {
        for overlay in pageOverlays.values { overlay.cancelCurrentEditor() }
        requestedEditor = nil
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
    }

    func pdfView(_ pdfView: PDFView, willEndDisplayingOverlayView overlayView: NSView, for page: PDFPage) {
        pageOverlays.removeValue(forKey: ObjectIdentifier(page))
    }

    override func mouseDown(with event: NSEvent) {
        guard let workspace else { return }
        window?.makeFirstResponder(self)
        let viewPoint = convert(event.locationInWindow, from: nil)

        if let selected = workspace.selectedAnnotation,
           let page = selected.page,
           let mode = resizeHandle(at: viewPoint, for: selected, on: page) {
            beginAnnotationDrag(selected, on: page, at: viewPoint, mode: mode)
            return
        }

        if workspace.activeTool == .fillForms {
            workspace.selectAnnotation(nil)
            super.mouseDown(with: event)
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
                if let annotation = page.annotation(at: pagePoint) {
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
        if workspace.activeTool == .draw || workspace.activeTool == .rectangle ||
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
        if annotationDidChange, let annotation = draggedAnnotation {
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
        annotationDidChange = false
        annotationOriginalPaths.removeAll()
        interactionOverlay.needsDisplay = true
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
        draggedAnnotation = annotation
        draggedAnnotationPage = page
        annotationDragStart = point
        annotationOriginalViewBounds = rect
        annotationOriginalPageBounds = annotation.bounds
        annotationOriginalPaths = copiedPaths(from: annotation)
        annotationWasDirty = workspace?.isDirty ?? false
        annotationDidChange = false
    }

    private func resizeHandle(at point: CGPoint, for annotation: PDFAnnotation, on page: PDFPage) -> AnnotationDragMode? {
        let rect = convert(annotation.bounds, from: page).standardized.insetBy(dx: -3, dy: -3)
        let threshold: CGFloat = 12
        let corners: [(AnnotationDragMode, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY))
        ]
        return corners.first { hypot($0.1.x - point.x, $0.1.y - point.y) <= threshold }?.0
    }

    private func updateAnnotationDrag(to point: CGPoint, workspace: PDFWorkspace) {
        guard let annotation = draggedAnnotation, let page = draggedAnnotationPage,
              let mode = annotationDragMode else { return }
        let delta = CGPoint(x: point.x - annotationDragStart.x, y: point.y - annotationDragStart.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        var rect = annotationOriginalViewBounds
        switch mode {
        case .move:
            rect = rect.offsetBy(dx: delta.x, dy: delta.y)
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
        annotationsChanged(on: page)
        needsDisplay = true
        annotationDidChange = true
        workspace.changed(mode == .move ? "Annotation moved" : "Annotation resized")
        interactionOverlay.needsDisplay = true
    }

    fileprivate func drawInteractionOverlay() {
        guard let workspace else { return }

        if let annotation = workspace.selectedAnnotation, let page = annotation.page {
            let rect = convert(annotation.bounds, from: page).standardized.insetBy(dx: -3, dy: -3)
            let outline = NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3)
            outline.lineWidth = 2
            outline.setLineDash([6, 3], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
            outline.stroke()

            for point in [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.minX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
            ] {
                let handle = NSBezierPath(ovalIn: CGRect(x: point.x - 3.5, y: point.y - 3.5, width: 7, height: 7))
                NSColor.white.setFill()
                handle.fill()
                NSColor.controlAccentColor.setStroke()
                handle.lineWidth = 1.5
                handle.stroke()
            }
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
