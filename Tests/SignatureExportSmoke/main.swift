import AppKit
import PDFKit

/// An image signature has to reach the file, not just the screen.
///
/// It is an annotation that draws itself. An ordinary write keeps it, but burning
/// annotations into the page — the flattened export — drew the placeholder PDFKit has for a
/// stamp it knows nothing about instead: a box with a cross through it.
@main
@MainActor
struct SignatureExportSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-signature-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.signature.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("R"))
        )
        workspace.load(makePDF(in: directory))
        guard let document = workspace.pdfDocument, let page = document.page(at: 0) else {
            fail("The fixture has no page")
        }

        // A signature in solid red, so it can be found in the page's pixels, and an ordinary
        // annotation beside it that has to stay an annotation.
        let signatureBounds = CGRect(x: 100, y: 100, width: 80, height: 40)
        page.addAnnotation(ImageStampAnnotation(bounds: signatureBounds, image: solidImage(.red)))
        let square = PDFAnnotation(bounds: CGRect(x: 20, y: 300, width: 60, height: 40), forType: .square, withProperties: nil)
        square.color = .blue
        page.addAnnotation(square)
        let signatureCentre = CGPoint(x: signatureBounds.midX, y: signatureBounds.midY)

        // An ordinary save keeps the signature as it is: an annotation, with its image, that
        // can still be moved after the file is opened again.
        let saved = directory.appendingPathComponent("saved.pdf")
        check(document.write(to: saved), "The signed document could not be written")
        guard let savedDocument = PDFDocument(url: saved), let savedPage = savedDocument.page(at: 0) else {
            fail("The saved file has no page")
        }
        check(isRed(savedPage, at: signatureCentre), "The saved file shows no signature where it was placed")
        check(
            savedPage.annotations.contains { $0.isSubtype(.stamp) },
            "An ordinary save took the signature out of the annotations"
        )

        // The flattened export shows it too, which is where the crossed box was found, and
        // the page keeps its text and its ordinary annotations burned in beside it.
        let flattened = directory.appendingPathComponent("flattened.pdf")
        check(
            workspace.writeFlattenedCopy(of: document, to: flattened, extraOptions: [:]),
            "The flattened copy could not be written"
        )
        guard let flatDocument = PDFDocument(url: flattened), let flatPage = flatDocument.page(at: 0) else {
            fail("The flattened file has no page")
        }
        check(isRed(flatPage, at: signatureCentre), "The flattened copy shows no signature where it was placed")
        check((flatPage.string ?? "").contains("Firmato"), "Flattening the signature in lost the page's text")
        check(
            isColour(flatPage, at: CGPoint(x: 20, y: 320), blue: true),
            "The ordinary annotation beside the signature was not burned in"
        )

        // The document on screen is left alone: the signature there is still an annotation
        // that can be moved.
        check(
            page.annotations.contains { $0 is ImageStampAnnotation },
            "Writing a copy took the movable signature out of the open document"
        )

        // A document with no image signature is written exactly as it was, without a copy.
        let plain = PDFDocument()
        plain.insert(PDFPage(), at: 0)
        check(StampBurner.prepared(plain) === plain, "A document with nothing to write in was copied anyway")

        print("Signature export smoke test passed.")
    }

    private static func isRed(_ page: PDFPage, at point: CGPoint) -> Bool {
        isColour(page, at: point, blue: false)
    }

    /// Whether the page, rendered, is plainly red — or blue — around `point`.
    private static func isColour(_ page: PDFPage, at point: CGPoint, blue: Bool) -> Bool {
        let box = page.bounds(for: .mediaBox)
        let width = Int(box.width), height = Int(box.height)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return false }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        page.draw(with: .mediaBox, to: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { return false }
        var red = 0
        for dy in -3...3 {
            for dx in -3...3 {
                let x = Int(point.x - box.minX) + dx
                let y = height - 1 - (Int(point.y - box.minY) + dy)
                guard x >= 0, x < width, y >= 0, y < height else { continue }
                let i = (y * width + x) * 4
                let (r, g, b) = (data[i], data[i + 1], data[i + 2])
                if blue ? (b > 200 && r < 80 && g < 80) : (r > 200 && g < 60 && b < 60) { red += 1 }
            }
        }
        return red > (blue ? 0 : 30)
    }

    private static func solidImage(_ color: NSColor) -> NSImage {
        let image = NSImage(size: NSSize(width: 160, height: 80))
        image.lockFocus()
        color.setFill()
        NSRect(x: 0, y: 0, width: 160, height: 80).fill()
        image.unlockFocus()
        return image
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("da-firmare.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fail("No PDF context") }
        context.beginPDFPage(nil)
        let line = NSAttributedString(
            string: "Firmato in fondo",
            attributes: [.font: CTFontCreateWithName("Helvetica" as CFString, 14, nil)]
        )
        context.textPosition = CGPoint(x: 30, y: 360)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Signature export smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
