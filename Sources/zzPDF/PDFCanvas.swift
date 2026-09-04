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
            workspace.selectAnnotation(notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation)
        }
    }
}

final class InteractivePDFView: PDFView {
    private enum AnnotationDragMode { case move, topLeft, topRight, bottomLeft, bottomRight }

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
    private var annotationUndoRecorded = false
    private lazy var interactionOverlay: PDFInteractionOverlay = {
        let overlay = PDFInteractionOverlay(frame: bounds)
        overlay.owner = self
        overlay.autoresizingMask = [.width, .height]
        return overlay
    }()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        addSubview(interactionOverlay, positioned: .above, relativeTo: nil)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        addSubview(interactionOverlay, positioned: .above, relativeTo: nil)
    }

    override func layout() {
        super.layout()
        interactionOverlay.frame = bounds
        interactionOverlay.needsDisplay = true
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
        addCursorRect(bounds, cursor: interactionCursor)
    }

    override func cursorUpdate(with event: NSEvent) {
        interactionCursor.set()
    }

    override func mouseMoved(with event: NSEvent) {
        let viewPoint = convert(event.locationInWindow, from: nil)
        if let page = page(for: viewPoint, nearest: false) {
            hoverPage = page
            hoverPoint = convert(viewPoint, to: page)
        } else {
            hoverPage = nil
            hoverPoint = nil
        }
        interactionCursor.set()
        interactionOverlay.needsDisplay = true
        super.mouseMoved(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        hoverPage = nil
        hoverPoint = nil
        interactionOverlay.needsDisplay = true
        super.mouseExited(with: event)
    }

    private var interactionCursor: NSCursor {
        guard let tool = workspace?.activeTool else { return .arrow }
        switch tool {
        case .select: return .arrow
        case .text: return .iBeam
        case .note, .draw, .rectangle, .oval, .redact, .signature: return .crosshair
        }
    }

    func refreshInteractionAppearance() {
        window?.acceptsMouseMovedEvents = true
        discardCursorRects()
        interactionCursor.set()
        interactionOverlay.needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard let workspace else { return }
        let viewPoint = convert(event.locationInWindow, from: nil)

        if workspace.activeTool == .select {
            if let page = page(for: viewPoint, nearest: false) {
                let pagePoint = convert(viewPoint, to: page)
                if let annotation = page.annotation(at: pagePoint), annotation.type != PDFAnnotationSubtype.widget.rawValue {
                    workspace.selectAnnotation(annotation)
                    if event.clickCount == 2 { workspace.beginEditingSelectedNote() }
                    beginAnnotationDrag(annotation, on: page, at: viewPoint)
                    return
                }
            }
            workspace.selectAnnotation(nil)
            interactionOverlay.needsDisplay = true
            super.mouseDown(with: event)
            return
        }

        guard let page = page(for: viewPoint, nearest: true) else { return }
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
        if workspace.activeTool == .select, draggedAnnotation != nil {
            updateAnnotationDrag(to: convert(event.locationInWindow, from: nil), workspace: workspace)
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
        if workspace.activeTool == .select, draggedAnnotation != nil {
            draggedAnnotation = nil
            draggedAnnotationPage = nil
            annotationDragMode = nil
            annotationUndoRecorded = false
            interactionOverlay.needsDisplay = true
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

    private func beginAnnotationDrag(_ annotation: PDFAnnotation, on page: PDFPage, at point: CGPoint) {
        let rect = convert(annotation.bounds, from: page).standardized
        let threshold: CGFloat = 11
        let corners: [(AnnotationDragMode, CGPoint)] = [
            (.topLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.maxY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.minY))
        ]
        annotationDragMode = corners.first(where: {
            hypot($0.1.x - point.x, $0.1.y - point.y) <= threshold
        })?.0 ?? .move
        draggedAnnotation = annotation
        draggedAnnotationPage = page
        annotationDragStart = point
        annotationOriginalViewBounds = rect
        annotationUndoRecorded = false
    }

    private func updateAnnotationDrag(to point: CGPoint, workspace: PDFWorkspace) {
        guard let annotation = draggedAnnotation, let page = draggedAnnotationPage,
              let mode = annotationDragMode else { return }
        let delta = CGPoint(x: point.x - annotationDragStart.x, y: point.y - annotationDragStart.y)
        guard abs(delta.x) > 0.5 || abs(delta.y) > 0.5 else { return }
        if !annotationUndoRecorded {
            workspace.recordUndoState()
            annotationUndoRecorded = true
        }

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
        annotation.bounds = convert(rect, to: page).standardized
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
        path.lineWidth = max(workspace.lineWidth, 1.5)
        path.setLineDash([7, 4], count: 2, phase: 0)
        if workspace.activeTool == .redact {
            NSColor.black.withAlphaComponent(0.62).setFill()
            path.fill()
            NSColor.white.withAlphaComponent(0.9).setStroke()
        } else {
            color.withAlphaComponent(0.16).setFill()
            path.fill()
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

final class PDFInteractionOverlay: NSView {
    weak var owner: InteractivePDFView?
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        owner?.drawInteractionOverlay()
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
