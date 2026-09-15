import AppKit
import PDFKit

@main
@MainActor
struct OCRSearchableSmoke {
    static let scanned = "FATTURA NUMERO 4471"
    static let typed = "Questa pagina ha gia il testo."

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-ocr-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = makeDocument()
        check(document.pageCount == 2, "The fixture has \(document.pageCount) pages instead of 2")
        check(
            OCRTextLayer.scannedPageIndexes(in: document) == [0],
            "The scanned page was not the only one picked for recognition"
        )

        guard let page = document.page(at: 0), let rendered = OCRTextLayer.render(page) else {
            fail("The scanned page could not be rendered")
        }
        let lines = OCRTextLayer.recognizedLines(in: rendered.image)
        guard !lines.isEmpty else { fail("Vision recognized nothing on the scanned page") }
        let recognizedText = lines.map(\.text).joined(separator: " ")
        check(
            recognizedText.uppercased().contains("FATTURA"),
            "Recognition read \"\(recognizedText)\" instead of the scanned heading"
        )

        guard let searchable = OCRTextLayer.searchablePage(
            image: rendered.image,
            pointSize: rendered.pointSize,
            lines: lines
        ) else {
            fail("The searchable page could not be built")
        }

        let originalBounds = page.bounds(for: .cropBox)
        let newBounds = searchable.bounds(for: .cropBox)
        check(
            abs(newBounds.width - originalBounds.width) < 1 && abs(newBounds.height - originalBounds.height) < 1,
            "The rebuilt page measures \(newBounds.size) instead of \(originalBounds.size)"
        )

        // The rebuilt page has to carry real, findable text.
        let rebuilt = PDFDocument()
        rebuilt.insert(searchable, at: 0)
        let extracted = (rebuilt.page(at: 0)?.string ?? "").uppercased()
        check(extracted.contains("FATTURA"), "The rebuilt page exposes \"\(extracted)\" instead of the scanned text")
        check(
            !rebuilt.findString("FATTURA", withOptions: .caseInsensitive).isEmpty,
            "The rebuilt page is not searchable"
        )

        // It has to survive a round trip through a written file.
        let url = directory.appendingPathComponent("searchable.pdf")
        check(rebuilt.write(to: url), "The searchable copy could not be written")
        guard let reopened = PDFDocument(url: url) else { fail("The searchable copy could not be reopened") }
        check(
            !reopened.findString("FATTURA", withOptions: .caseInsensitive).isEmpty,
            "A saved searchable page lost its text"
        )

        // The invisible layer must not change what the page looks like.
        check(
            inkDifference(between: page, and: searchable) < 0.02,
            "The searchable page no longer looks like the scan it replaced"
        )

        // A page that already has text is left alone.
        check(
            OCRTextLayer.scannedPageIndexes(in: rebuiltDocumentWithTypedPage()) == [],
            "A page that already has text was queued for recognition"
        )

        print("Searchable OCR smoke test passed.")
    }

    private static func rebuiltDocumentWithTypedPage() -> PDFDocument {
        let document = PDFDocument()
        if let page = makeTypedPage() { document.insert(page, at: 0) }
        return document
    }

    /// Fraction of pixels that differ between two renderings of the same page.
    private static func inkDifference(between first: PDFPage, and second: PDFPage) -> Double {
        guard let a = OCRTextLayer.render(first, dpi: 72).map({ NSBitmapImageRep(cgImage: $0.image) }),
              let b = OCRTextLayer.render(second, dpi: 72).map({ NSBitmapImageRep(cgImage: $0.image) })
        else { return 1 }
        let width = min(a.pixelsWide, b.pixelsWide)
        let height = min(a.pixelsHigh, b.pixelsHigh)
        guard width > 0, height > 0 else { return 1 }
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let first = a.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let second = b.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                if abs(first.brightnessComponent - second.brightnessComponent) > 0.3 { differing += 1 }
            }
        }
        return Double(differing) / Double(width * height)
    }

    /// Page one imitates a scan: text drawn into a bitmap, so the PDF holds no text at all.
    private static func makeDocument() -> PDFDocument {
        let document = PDFDocument()
        let size = NSSize(width: 400, height: 220)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
        NSAttributedString(
            string: scanned,
            attributes: [.font: NSFont(name: "Helvetica-Bold", size: 34)!, .foregroundColor: NSColor.black]
        ).draw(at: NSPoint(x: 24, y: 120))
        image.unlockFocus()
        if let page = PDFPage(image: image) { document.insert(page, at: 0) }
        if let page = makeTypedPage() { document.insert(page, at: document.pageCount) }
        return document
    }

    private static func makeTypedPage() -> PDFPage? {
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 220)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributed = NSAttributedString(string: typed, attributes: [.font: font])
        context.textPosition = CGPoint(x: 30, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
        context.endPDFPage()
        context.closePDF()
        return PDFDocument(data: data as Data)?.page(at: 0)
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Searchable OCR smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
