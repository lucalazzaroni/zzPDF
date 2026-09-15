import AppKit
import PDFKit
@preconcurrency import Vision

/// Turns scanned pages into searchable ones. PDFKit cannot add text to an existing page,
/// so a recognized page is rebuilt: the rendered image goes down first, then the
/// recognized words are drawn on top in invisible text mode. The page looks identical and
/// every PDF reader can select, copy, and search what the scan says.
enum OCRTextLayer {
    struct RecognizedLine: Sendable {
        /// Normalized to the page, origin bottom-left, as Vision reports it.
        let box: CGRect
        let text: String
    }

    static let renderDPI: CGFloat = 200

    /// Pages with no extractable text: the ones worth recognizing.
    static func scannedPageIndexes(in document: PDFDocument) -> [Int] {
        (0..<document.pageCount).filter { index in
            let text = document.page(at: index)?.string ?? ""
            return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func render(_ page: PDFPage, dpi: CGFloat = renderDPI) -> (image: CGImage, pointSize: CGSize)? {
        let box = PDFDisplayBox.cropBox
        let bounds = page.bounds(for: box)
        guard bounds.width > 1, bounds.height > 1 else { return nil }
        let rotated = abs(page.rotation % 180) == 90
        let pointSize = rotated
            ? CGSize(width: bounds.height, height: bounds.width)
            : bounds.size
        let scale = dpi / 72
        let width = max(1, Int((pointSize.width * scale).rounded()))
        let height = max(1, Int((pointSize.height * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.interpolationQuality = .high
        page.draw(with: box, to: context)
        guard let image = context.makeImage() else { return nil }
        return (image, pointSize)
    }

    static func recognizedLines(in image: CGImage) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = preferredLanguages()
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let observations = request.results else { return [] }
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first,
                  !candidate.string.isEmpty else { return nil }
            return RecognizedLine(box: observation.boundingBox, text: candidate.string)
        }
    }

    static func preferredLanguages() -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        guard !supported.isEmpty else { return [] }
        var chosen = Locale.preferredLanguages.compactMap { tag -> String? in
            let code = Locale(identifier: tag).language.languageCode?.identifier
            return supported.first { $0 == tag || $0.hasPrefix("\(code ?? "--")-") || $0 == code }
        }
        if let english = supported.first(where: { $0.hasPrefix("en") }), !chosen.contains(english) {
            chosen.append(english)
        }
        return chosen.isEmpty ? [] : Array(NSOrderedSet(array: chosen)) as? [String] ?? []
    }

    /// A page showing `image` with `lines` drawn over it in invisible text.
    static func searchablePage(
        image: CGImage,
        pointSize: CGSize,
        lines: [RecognizedLine]
    ) -> PDFPage? {
        var mediaBox = CGRect(origin: .zero, size: pointSize)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.setTextDrawingMode(.invisible)
        context.setFillColor(NSColor.black.cgColor)
        for line in lines {
            draw(line, in: context, pageSize: pointSize)
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(data: data as Data) else { return nil }
        return document.page(at: 0)
    }

    private static func draw(_ line: RecognizedLine, in context: CGContext, pageSize: CGSize) {
        let rect = CGRect(
            x: line.box.minX * pageSize.width,
            y: line.box.minY * pageSize.height,
            width: line.box.width * pageSize.width,
            height: line.box.height * pageSize.height
        )
        guard rect.width > 0.5, rect.height > 0.5 else { return }

        let font = CTFontCreateWithName("Helvetica" as CFString, max(1, rect.height * 0.8), nil)
        let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
        let ctLine = CTLineCreateWithAttributedString(attributed)
        let measured = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard measured > 0 else { return }

        // Squeeze the line horizontally so the invisible text covers the same span as the
        // words in the image, which is what makes selection land where the reader expects.
        context.saveGState()
        context.textMatrix = CGAffineTransform(scaleX: rect.width / CGFloat(measured), y: 1)
        context.textPosition = CGPoint(x: rect.minX, y: rect.minY + rect.height * 0.15)
        CTLineDraw(ctLine, context)
        context.restoreGState()
    }
}
