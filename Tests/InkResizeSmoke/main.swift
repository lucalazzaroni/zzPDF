import AppKit
import PDFKit

let originalBounds = CGRect(x: 20, y: 30, width: 40, height: 20)
let annotation = ScalableInkAnnotation(
    bounds: originalBounds,
    pageStrokes: [[
        CGPoint(x: originalBounds.minX, y: originalBounds.minY),
        CGPoint(x: originalBounds.maxX, y: originalBounds.maxY)
    ]],
    color: .black,
    lineWidth: 2
)

let resizedBounds = CGRect(x: 10, y: 15, width: 120, height: 80)
annotation.resize(to: resizedBounds)

guard let pathBounds = annotation.paths?.first?.bounds,
      annotation.bounds == resizedBounds,
      abs(pathBounds.minX) < 0.01,
      abs(pathBounds.minY) < 0.01,
      abs(pathBounds.width - resizedBounds.width) < 0.01,
      abs(pathBounds.height - resizedBounds.height) < 0.01 else {
    fatalError("Ink paths were not rebuilt at the resized dimensions.")
}

print("Ink resize smoke test passed.")
