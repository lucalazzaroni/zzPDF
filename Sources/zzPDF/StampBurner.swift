import AppKit
import PDFKit

/// Writes image signatures into the page before a document is flattened.
///
/// A signature made from an image is an annotation that draws itself. An ordinary write
/// keeps it — PDFKit records what it draws as the annotation's appearance — but burning
/// annotations into the page does not use that: it draws the placeholder PDFKit has for a
/// stamp it knows nothing about, a box with a cross through it, which is what a flattened
/// export showed in place of the signature. Put into the page's own content first, the
/// signature is simply part of the page by the time anything is burned in.
///
/// The document on screen is never touched: the signature stays movable there.
enum StampBurner {
    /// `document` itself if it holds no image signatures, otherwise a copy that carries
    /// them in its pages. Only for flattening: written any other way, the signature is
    /// better kept as an annotation, which a reader can still move.
    static func prepared(_ document: PDFDocument) -> PDFDocument {
        let signed = (0..<document.pageCount).filter { index in
            document.page(at: index)?.annotations.contains { $0 is ImageStampAnnotation } == true
        }
        guard !signed.isEmpty,
              let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data) else { return document }

        for index in signed {
            guard let live = document.page(at: index), let written = copy.page(at: index) else { continue }
            let stamps = live.annotations.compactMap { $0 as? ImageStampAnnotation }

            // The copy holds each signature as the bare stamp PDFKit wrote. Those go; what
            // they stood for is drawn into the page instead.
            for annotation in written.annotations
            where annotation.isSubtype(.stamp) && stamps.contains(where: { near($0.bounds, annotation.bounds) }) {
                written.removeAnnotation(annotation)
            }
            guard let rebuilt = try? TextReplacementWriter.redraw(written, adding: { context in
                for stamp in stamps { stamp.draw(with: .cropBox, in: context) }
            }) else { continue }
            TextReplacementWriter.transferAnnotations(from: written, to: rebuilt)
            copy.removePage(at: index)
            copy.insert(rebuilt, at: index)
        }
        return copy
    }

    private static func near(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1 && abs(a.minY - b.minY) < 1
            && abs(a.width - b.width) < 1 && abs(a.height - b.height) < 1
    }
}
