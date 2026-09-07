import AppKit
import PDFKit

final class ScalableInkAnnotation: PDFAnnotation {
    private var normalizedStrokes: [[CGPoint]]
    private let inkLineWidth: CGFloat

    init(bounds: CGRect, pageStrokes: [[CGPoint]], color: NSColor, lineWidth: CGFloat) {
        self.inkLineWidth = lineWidth
        self.normalizedStrokes = pageStrokes.map { stroke in
            stroke.map {
                CGPoint(
                    x: bounds.width > 0 ? ($0.x - bounds.minX) / bounds.width : 0,
                    y: bounds.height > 0 ? ($0.y - bounds.minY) / bounds.height : 0
                )
            }
        }
        super.init(bounds: bounds, forType: .ink, withProperties: nil)
        self.color = color
        let inkBorder = PDFBorder()
        inkBorder.lineWidth = lineWidth
        border = inkBorder
        rebuildPDFPaths()
    }

    required init?(coder: NSCoder) {
        normalizedStrokes = []
        inkLineWidth = 2
        super.init(coder: coder)
    }

    func resize(to newBounds: CGRect) {
        bounds = newBounds
        rebuildPDFPaths()
    }

    private func rebuildPDFPaths() {
        for path in paths ?? [] { remove(path) }
        for stroke in normalizedStrokes where stroke.count > 1 {
            let path = NSBezierPath()
            path.move(to: CGPoint(x: stroke[0].x * bounds.width, y: stroke[0].y * bounds.height))
            for point in stroke.dropFirst() {
                path.line(to: CGPoint(x: point.x * bounds.width, y: point.y * bounds.height))
            }
            add(path)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard !normalizedStrokes.isEmpty else {
            super.draw(with: box, in: context)
            return
        }
        context.saveGState()
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(inkLineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in normalizedStrokes where stroke.count > 1 {
            context.beginPath()
            context.move(to: CGPoint(
                x: bounds.minX + stroke[0].x * bounds.width,
                y: bounds.minY + stroke[0].y * bounds.height
            ))
            for point in stroke.dropFirst() {
                context.addLine(to: CGPoint(
                    x: bounds.minX + point.x * bounds.width,
                    y: bounds.minY + point.y * bounds.height
                ))
            }
            context.strokePath()
        }
        context.restoreGState()
    }
}
