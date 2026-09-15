import AppKit
import PDFKit

/// Makes redactions real. Burning a black rectangle into a page only covers the words:
/// the text objects underneath stay in the content stream, so the exported file can still
/// be searched, selected, and copied. The only way to remove them with PDFKit alone is to
/// replace the affected pages with a rendered image of themselves.
enum RedactionFlattener {
    static let marker = "Redaction — export a flattened copy"

    /// Rendering resolution for redacted pages. High enough for small print to stay
    /// readable, low enough that a page does not balloon the exported file.
    static let renderDPI: CGFloat = 200
    private static let maximumPixels = 40_000_000

    static func isRedaction(_ annotation: PDFAnnotation) -> Bool {
        annotation.contents == marker
    }

    static func redactedPageIndexes(in document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { index in
            document.page(at: index)?.annotations.contains(where: isRedaction) == true
        }
    }

    static func exportWarning(redactedPageCount: Int) -> String {
        guard redactedPageCount > 0 else {
            return "Annotations will be permanently applied to the exported copy."
        }
        let pages = redactedPageCount == 1 ? "1 page" : "\(redactedPageCount) pages"
        return """
        Annotations will be permanently applied to the exported copy.

        \(pages) contain a redaction and will be exported as images so the hidden text is \
        really gone. Text on those pages will no longer be selectable or searchable.
        """
    }

    /// A copy of `document` in which every redacted page has become an image of itself.
    /// Returns `nil` when there is nothing to redact, so the caller can export the
    /// document unchanged and keep its text intact.
    static func rasterizingRedactedPages(of document: PDFDocument) -> PDFDocument? {
        let redacted = redactedPageIndexes(in: document)
        guard !redacted.isEmpty else { return nil }
        guard let data = document.dataRepresentation(),
              let copy = PDFDocument(data: data),
              copy.pageCount == document.pageCount else { return nil }

        for index in redacted {
            guard let page = copy.page(at: index), let rendered = rasterized(page) else { continue }
            copy.removePage(at: index)
            copy.insert(rendered, at: index)
        }
        return copy
    }

    private static func rasterized(_ page: PDFPage) -> PDFPage? {
        let box = PDFDisplayBox.cropBox
        let bounds = page.bounds(for: box)
        guard bounds.width > 1, bounds.height > 1 else { return nil }

        // A rotated page renders with its sides swapped, so the image, and the page built
        // from it, has to use the rotated extent.
        let rotated = abs(page.rotation % 180) == 90
        let pointSize = rotated
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size

        var scale = renderDPI / 72
        while Int(pointSize.width * scale) * Int(pointSize.height * scale) > maximumPixels, scale > 1 {
            scale -= 0.25
        }
        let pixelWidth = max(1, Int((pointSize.width * scale).rounded()))
        let pixelHeight = max(1, Int((pointSize.height * scale).rounded()))

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        page.draw(with: box, to: context)

        guard let image = context.makeImage() else { return nil }
        let rendition = NSImage(cgImage: image, size: pointSize)
        guard let rasterizedPage = PDFPage(image: rendition) else { return nil }
        rasterizedPage.setBounds(CGRect(origin: .zero, size: pointSize), for: .mediaBox)
        return rasterizedPage
    }
}
