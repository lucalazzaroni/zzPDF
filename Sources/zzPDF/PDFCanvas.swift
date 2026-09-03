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
            workspace.selectedAnnotation = notification.userInfo?["PDFAnnotationHit"] as? PDFAnnotation
        }
    }
}

final class InteractivePDFView: PDFView {
    weak var workspace: PDFWorkspace?
    private var gesturePoints: [CGPoint] = []
    private weak var gesturePage: PDFPage?

    override func mouseDown(with event: NSEvent) {
        guard let workspace, workspace.activeTool != .select else {
            super.mouseDown(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        guard let page = page(for: viewPoint, nearest: true) else { return }
        gesturePage = page
        gesturePoints = [convert(viewPoint, to: page)]
        if workspace.activeTool == .note || workspace.activeTool == .text || workspace.activeTool == .signature {
            workspace.addAnnotation(at: gesturePoints[0], on: page)
            gesturePoints.removeAll()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let workspace, workspace.activeTool != .select,
              let page = gesturePage else {
            super.mouseDragged(with: event)
            return
        }
        let viewPoint = convert(event.locationInWindow, from: nil)
        gesturePoints.append(convert(viewPoint, to: page))
    }

    override func mouseUp(with event: NSEvent) {
        guard let workspace, workspace.activeTool != .select,
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
    }
}
