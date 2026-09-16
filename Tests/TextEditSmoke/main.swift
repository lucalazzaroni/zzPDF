import AppKit
import PDFKit

@main
@MainActor
struct TextEditSmoke {
    static let headline = "Hello Acrobat World"
    static let firstBodyLine = "A second line of body text"
    static let secondBodyLine = "that continues on this line."

    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-textedit-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.textedit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let source = makeSourcePDF(in: directory)
        let recoveryStore = TemporaryRecoveryStore(
            directoryURL: directory.appendingPathComponent("Recovery", isDirectory: true)
        )

        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: recoveryStore
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 460, height: 360))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(source)
        view.document = workspace.pdfDocument
        view.layoutDocumentView()

        guard let document = workspace.pdfDocument, let page = document.page(at: 0) else {
            fail("The prepared document could not be opened")
        }
        workspace.activeTool = .editText
        let annotationsBefore = page.annotations.count

        // A click detects the whole line, its font, its color, and its paper color.
        guard let detected = workspace.replaceableText(at: CGPoint(x: 60, y: 342), on: page) else {
            fail("No replaceable text was detected under the headline")
        }
        check(detected.text == headline, "Detected \"\(detected.text)\" instead of \"\(headline)\"")
        check(detected.font.fontName == "Helvetica", "Detected font \(detected.font.fontName) instead of Helvetica")
        check(abs(detected.font.pointSize - 20) < 0.01, "Detected size \(detected.font.pointSize) instead of 20")
        check(abs(detected.firstBaseline - 340) < 0.05, "Detected baseline \(detected.firstBaseline) instead of 340")
        check(!detected.isMultiline, "A single click produced a multiline block")
        let paper = detected.backgroundColor.usingColorSpace(.deviceRGB)!
        check(
            abs(paper.redComponent - 0.95) < 0.05 && abs(paper.blueComponent - 0.88) < 0.05,
            "The tinted paper color was read as \(paper) instead of the beige band"
        )

        // Replacing the line adds an opaque cover plus the editable text, as one linked pair.
        workspace.beginTextReplacement(detected)
        check(
            page.annotations.count == annotationsBefore + 2,
            "Replacing a line added \(page.annotations.count - annotationsBefore) annotations instead of 2"
        )
        guard let replaced = workspace.selectedAnnotation, replaced.isSubtype(.freeText) else {
            fail("The replacement text annotation was not selected")
        }
        guard let cover = workspace.linkedCover(for: replaced) else {
            fail("The replacement text has no linked cover")
        }
        check(workspace.textAnnotation(forCover: cover) === replaced, "The cover does not point back to its text")
        check(TextEditMarker.isTextEdit(replaced) && TextEditMarker.isTextEdit(cover), "The pair is not marked as a text edit")
        check(replaced.userName == cover.userName, "The pair does not share one identifier")
        check(cover.isSubtype(.square) && cover.interiorColor != nil, "The cover is not an opaque square")
        check(replaced.contents == headline, "The editor was seeded with \"\(replaced.contents ?? "")\"")
        check(
            abs((FreeTextLayout.baseline(of: replaced) ?? 0) - 340) < 0.05,
            "The replacement sits on baseline \(FreeTextLayout.baseline(of: replaced) ?? 0) instead of 340"
        )
        check(cover.bounds.contains(detected.coverBounds.insetBy(dx: 0.5, dy: 0.5)), "The cover does not hide the original text")

        // Committing keeps the pair, records one undo step, and restores both annotations.
        workspace.commitTextReplacement(replaced, text: "Ciao mondo")
        check(replaced.contents == "Ciao mondo", "The committed text is \"\(replaced.contents ?? "")\"")
        check(replaced.shouldDisplay, "The replacement stayed hidden after committing")
        check(workspace.isDirty, "Replacing page text did not mark the document as edited")
        check(workspace.canUndo, "Replacing page text registered no undo step")
        workspace.undo()
        check(
            page.annotations.count == annotationsBefore,
            "Undo left \(page.annotations.count - annotationsBefore) annotations behind"
        )
        workspace.redo()
        check(
            page.annotations.count == annotationsBefore + 2,
            "Redo restored \(page.annotations.count - annotationsBefore) annotations instead of 2"
        )

        // Moving the replacement drags its cover along.
        let coverBefore = cover.bounds
        let moved = replaced.bounds.offsetBy(dx: 12, dy: -7)
        replaced.bounds = moved
        workspace.synchronizeCover(for: replaced)
        check(
            cover.bounds == coverBefore.offsetBy(dx: 12, dy: -7),
            "The cover did not follow the replacement to \(moved)"
        )
        replaced.bounds = moved.offsetBy(dx: -12, dy: 7)
        workspace.synchronizeCover(for: replaced)
        check(cover.bounds == coverBefore, "Moving the replacement back did not restore the cover")

        // Shrinking the replacement must not uncover the text it hides.
        workspace.applyTextFont(TextFitting.resized(replaced.font!, to: 8), to: replaced)
        check(cover.bounds == coverBefore, "Shrinking the replacement moved its cover")
        workspace.applyTextFont(TextFitting.resized(replaced.font!, to: 20), to: replaced)

        // Resizing keeps the text on its original baseline instead of letting it drift.
        let baselineBefore = FreeTextLayout.baseline(of: replaced) ?? 0
        workspace.applyTextFont(TextFitting.resized(replaced.font!, to: 28), to: replaced)
        check(
            abs((FreeTextLayout.baseline(of: replaced) ?? 0) - baselineBefore) < 0.05,
            "Resizing moved the baseline to \(FreeTextLayout.baseline(of: replaced) ?? 0)"
        )
        workspace.applyTextFont(TextFitting.resized(replaced.font!, to: 20), to: replaced)

        // A slightly longer line widens into the margin at its original size.
        let pageBounds = page.bounds(for: .cropBox)
        let widened = TextFitting.fit(
            text: "Hello Acrobat World again",
            font: replaced.font!,
            in: replaced.bounds,
            multiline: false,
            within: pageBounds
        )
        check(
            abs(widened.font.pointSize - replaced.font!.pointSize) < 0.01,
            "A slightly longer line was shrunk to \(widened.font.pointSize) instead of widening"
        )
        check(widened.bounds.width > replaced.bounds.width, "A longer line did not widen its box")
        check(widened.bounds.maxX <= pageBounds.maxX, "The widened box left the page")

        // A much longer replacement shrinks, and only wraps once shrinking is exhausted.
        let long = String(repeating: "much longer replacement ", count: 4)
        let reflowed = TextFitting.fit(
            text: long,
            font: replaced.font!,
            in: replaced.bounds,
            multiline: false,
            within: pageBounds
        )
        check(reflowed.font.pointSize < replaced.font!.pointSize, "Overlong text was not shrunk")
        check(
            TextFitting.fits(long, font: reflowed.font, in: reflowed.bounds, multiline: true),
            "The reflowed text still does not fit its box"
        )
        check(reflowed.bounds.maxY == replaced.bounds.maxY, "Reflowing moved the top of the box")

        // Dragging across several lines replaces the whole block at once.
        guard let block = workspace.pdfDocument.flatMap({ _ in
            PageTextScanner.replaceableText(in: CGRect(x: 35, y: 276, width: 340, height: 40), on: page)
        }) else {
            fail("No replaceable block was detected across the body lines")
        }
        check(block.isMultiline, "A block spanning two lines was not reported as multiline")
        check(
            block.text == "\(firstBodyLine)\n\(secondBodyLine)",
            "The block reads \"\(block.text)\" instead of both body lines"
        )
        check(block.coverBounds.height > 20, "The block cover only spans \(block.coverBounds.height) points")
        check(block.lines.count == 2, "The block holds \(block.lines.count) lines instead of 2")

        // A block is replaced line by line, so the document's own line spacing survives
        // instead of being reflowed with the font's.
        let originalBaselines = block.lines.map(\.baseline)
        let beforeBlock = page.annotations.count
        workspace.beginTextReplacement(block)
        check(
            page.annotations.count == beforeBlock + 4,
            "Replacing two lines added \(page.annotations.count - beforeBlock) annotations instead of 4"
        )
        guard let blockText = workspace.selectedAnnotation else { fail("The block replacement was not selected") }
        let blockAnnotations = page.annotations
            .filter { $0.isSubtype(.freeText) && TextEditMarker.isTextEdit($0) && $0 !== replaced }
            .sorted { $0.bounds.maxY > $1.bounds.maxY }
        check(blockAnnotations.count == 2, "The block produced \(blockAnnotations.count) text boxes instead of 2")
        for (annotation, baseline) in zip(blockAnnotations, originalBaselines) {
            check(
                abs((FreeTextLayout.baseline(of: annotation) ?? 0) - baseline) < 0.05,
                "A replaced line sits on \(FreeTextLayout.baseline(of: annotation) ?? 0) instead of \(baseline)"
            )
            check(workspace.linkedCover(for: annotation) != nil, "A replaced line has no cover")
        }

        let longEnough = "Una prima riga piuttosto lunga da distribuire e poi il resto del testo."
        workspace.commitTextReplacement(blockText, text: longEnough)
        let written = blockAnnotations.map { ($0.contents ?? "") }
        check(
            written.joined(separator: " ").split(separator: " ") == longEnough.split(separator: " "),
            "The block was laid out as \(written) and lost or reordered words"
        )
        check(!written[0].isEmpty, "The first line of the block came out empty")
        check(
            blockAnnotations.allSatisfy { annotation in
                originalBaselines.contains { abs((FreeTextLayout.baseline(of: annotation) ?? 0) - $0) < 0.05 }
            },
            "Committing the block moved a line off its baseline"
        )

        // Undoing a block takes all four annotations with it, in one step.
        workspace.undo()
        check(
            page.annotations.count == beforeBlock,
            "Undoing the block left \(page.annotations.count - beforeBlock) annotations behind"
        )
        workspace.redo()
        check(page.annotations.count == beforeBlock + 4, "Redoing the block did not restore all four annotations")

        // Saving and reopening keeps both pairs linked.
        let saved = directory.appendingPathComponent("edited.pdf")
        check(document.write(to: saved), "The edited document could not be written")

        let reopened = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: recoveryStore
        )
        let reopenedView = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 460, height: 360))
        reopened.pdfView = reopenedView
        reopenedView.workspace = reopened
        reopened.load(saved)
        guard let reopenedPage = reopened.pdfDocument?.page(at: 0) else { fail("The saved document could not be reopened") }
        let reopenedTexts = reopenedPage.annotations.filter { $0.isSubtype(.freeText) && TextEditMarker.isTextEdit($0) }
        // One run for the headline, one for each line of the replaced block.
        check(reopenedTexts.count == 3, "The saved document holds \(reopenedTexts.count) replaced runs instead of 3")
        for text in reopenedTexts {
            check(reopened.linkedCover(for: text) != nil, "A reopened replacement lost its cover link")
        }
        check(
            reopenedTexts.contains { $0.contents == "Ciao mondo" },
            "The saved document lost the replaced headline"
        )

        // A click on the page goes through the canvas and opens the editor on that line.
        let clickWorkspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: recoveryStore
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 460),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let clickView = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 520, height: 460))
        window.contentView = clickView
        clickWorkspace.pdfView = clickView
        clickView.workspace = clickWorkspace
        clickWorkspace.load(source)
        clickView.document = clickWorkspace.pdfDocument
        clickView.autoScales = false
        clickView.scaleFactor = 1
        clickView.layoutDocumentView()
        clickWorkspace.activeTool = .editText
        guard let clickPage = clickWorkspace.pdfDocument?.page(at: 0) else { fail("The click fixture has no page") }
        let pagePoint = CGPoint(x: 90, y: 342)
        let viewPoint = clickView.convert(pagePoint, from: clickPage)
        check(
            clickView.page(for: viewPoint, nearest: false) === clickPage,
            "The canvas does not map \(viewPoint) back onto the page"
        )
        let windowPoint = clickView.convert(viewPoint, to: nil)
        guard let down = mouseEvent(.leftMouseDown, at: windowPoint, in: window),
              let up = mouseEvent(.leftMouseUp, at: windowPoint, in: window) else {
            fail("The synthetic click could not be created")
        }
        clickView.mouseDown(with: down)
        clickView.mouseUp(with: up)
        guard let clicked = clickWorkspace.selectedAnnotation, clicked.isSubtype(.freeText) else {
            fail("Clicking a line with the Edit Text tool did not start an edit")
        }
        check(clicked.contents == headline, "The click seeded \"\(clicked.contents ?? "")\" instead of the headline")
        check(clickWorkspace.linkedCover(for: clicked) != nil, "The clicked replacement has no cover")
        if let editor = clickView.activeInlineEditor {
            check(!clicked.shouldDisplay, "The annotation stayed visible behind its own editor")
            editor.commit()
            check(clicked.shouldDisplay, "Committing the editor left the replacement hidden")
            check(clicked.contents == headline, "The editor committed \"\(clicked.contents ?? "")\"")
            check(clickWorkspace.isDirty, "The editor commit did not mark the document as edited")
            clickWorkspace.undo()
            check(
                clickPage.annotations.isEmpty,
                "Undoing an in-place edit left \(clickPage.annotations.count) annotations on the page"
            )
        } else {
            clickWorkspace.cancelTextReplacement(clicked)
            check(
                clickPage.annotations.isEmpty,
                "Discarding a click left \(clickPage.annotations.count) annotations on the page"
            )
        }
        check(!clickWorkspace.isDirty, "The click fixture stayed marked as edited")

        // The editor lives in a page-space overlay that PDFKit scales with the zoom, so
        // its text stays at the PDF point size however far the page is zoomed. Scaling the
        // font here as well showed the text at the zoom factor over again.
        for zoom in [1.0, 2.5] as [CGFloat] {
            clickView.scaleFactor = zoom
            clickView.layoutDocumentView()
            clickWorkspace.beginTextReplacement(at: pagePoint, on: clickPage)
            guard let zoomed = clickWorkspace.selectedAnnotation else {
                fail("No replacement started at zoom \(zoom)")
            }
            if let editor = clickView.activeInlineEditor {
                let expected = zoomed.font?.pointSize ?? 0
                check(
                    abs(editor.displayedFontSize - expected) < 0.01,
                    "At zoom \(zoom) the editor draws \(editor.displayedFontSize) pt text for a \(expected) pt annotation"
                )
                check(
                    abs(editor.frame.width - zoomed.bounds.width) < 1.5
                        && abs(editor.frame.height - zoomed.bounds.height) < 1.5,
                    "At zoom \(zoom) the editor box is \(editor.frame.size) for annotation bounds \(zoomed.bounds.size)"
                )
            }
            clickWorkspace.cancelTextReplacement(zoomed)
            check(
                clickPage.annotations.isEmpty,
                "Discarding the zoom \(zoom) edit left \(clickPage.annotations.count) annotations"
            )
        }

        // Escape discards the edit and leaves the tool where it was; a second Escape is
        // what returns to Select. The key is sent for real, because which of the editor and
        // the menu sees it first is exactly what this has to survive.
        clickView.scaleFactor = 1
        clickView.layoutDocumentView()
        window.makeKeyAndOrderFront(nil)

        clickWorkspace.beginTextReplacement(at: pagePoint, on: clickPage)
        guard let discarded = clickWorkspace.selectedAnnotation else { fail("No replacement was started") }
        clickWorkspace.previewTextEdit("TESTO CHE NON DEVE RESTARE")
        check(discarded.contents == "TESTO CHE NON DEVE RESTARE", "Typing did not reach the annotation")
        if clickView.activeInlineEditor != nil {
            clickView.activeInlineEditor?.focus()
            sendEscape(to: window)
        } else {
            clickWorkspace.activateSelectTool()
        }
        check(
            clickPage.annotations.isEmpty,
            "Escape left \(clickPage.annotations.count) annotations from a discarded edit"
        )
        check(!clickWorkspace.isDirty, "Escape left the document marked as edited")
        check(clickWorkspace.activeTool == .editText, "The first Escape already left the Edit Text tool")

        clickWorkspace.activateSelectTool()
        check(clickWorkspace.activeTool == .select, "The second Escape did not return to Select")

        // Escape on a line that was already replaced puts back what was committed, rather
        // than removing the replacement or keeping what was just typed.
        clickWorkspace.activateTool(.editText)
        clickWorkspace.beginTextReplacement(at: pagePoint, on: clickPage)
        guard let kept = clickWorkspace.selectedAnnotation else { fail("No replacement was started") }
        clickWorkspace.commitTextReplacement(kept, text: "Versione buona")
        let keptCount = clickPage.annotations.count
        clickWorkspace.beginInlineTextEditing(kept)
        clickWorkspace.previewTextEdit("Ripensamento da buttare")
        clickWorkspace.activateSelectTool()
        check(kept.contents == "Versione buona", "Escape kept \"\(kept.contents ?? "")\" instead of the committed text")
        check(clickPage.annotations.count == keptCount, "Escape removed a replacement that had been committed")
        check(clickWorkspace.activeTool == .editText, "Escape on a re-edit already left the Edit Text tool")
        clickWorkspace.activateSelectTool()
        check(clickWorkspace.activeTool == .select, "The second Escape did not return to Select")

        // Replacing a line with itself has to be invisible on the page.
        check(replacementIsPixelAccurate(source: source), "Replacing text with itself changed the rendered page")

        print("Page text editing smoke test passed.")
    }

    private static func replacementIsPixelAccurate(source: URL) -> Bool {
        guard let original = PDFDocument(url: source), let originalPage = original.page(at: 0),
              let edited = PDFDocument(url: source), let editedPage = edited.page(at: 0) else { return false }
        for point in [CGPoint(x: 60, y: 342), CGPoint(x: 60, y: 302), CGPoint(x: 60, y: 284)] {
            guard let replacement = PageTextScanner.replaceableText(at: point, on: editedPage) else { return false }
            let bounds = replacement.textBounds
            let cover = PDFAnnotation(
                bounds: FreeTextLayout.coverBounds(for: bounds, font: replacement.font),
                forType: .square,
                withProperties: nil
            )
            cover.color = replacement.backgroundColor
            cover.interiorColor = replacement.backgroundColor
            let border = PDFBorder()
            border.lineWidth = 0
            cover.border = border
            editedPage.addAnnotation(cover)
            let text = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            text.contents = replacement.text
            text.font = replacement.font
            text.fontColor = replacement.fontColor
            text.color = .clear
            text.alignment = .left
            editedPage.addAnnotation(text)
        }
        guard let before = render(originalPage), let after = render(editedPage) else { return false }
        let width = min(before.pixelsWide, after.pixelsWide)
        let height = min(before.pixelsHigh, after.pixelsHigh)
        guard width > 0, height > 0 else { return false }
        var differing = 0
        for y in 0..<height {
            for x in 0..<width {
                guard let a = before.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      let b = after.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let delta = abs(a.redComponent - b.redComponent)
                    + abs(a.greenComponent - b.greenComponent)
                    + abs(a.blueComponent - b.blueComponent)
                if delta > 0.25 { differing += 1 }
            }
        }
        return Double(differing) / Double(width * height) < 0.005
    }

    private static func sendEscape(to window: NSWindow) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: 53
        ) else { return }
        window.sendEvent(event)
    }

    private static func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        )
    }

    private static func render(_ page: PDFPage) -> NSBitmapImageRep? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 3
        let image = page.thumbnail(of: CGSize(width: bounds.width * scale, height: bounds.height * scale), for: .mediaBox)
        guard let data = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: data)
    }

    private static func makeSourcePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("source.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 360)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        NSColor(calibratedRed: 0.95, green: 0.94, blue: 0.88, alpha: 1).setFill()
        NSBezierPath(rect: CGRect(x: 0, y: 320, width: 420, height: 40)).fill()
        draw(headline, font: NSFont(name: "Helvetica", size: 20)!, baseline: 340)
        draw(firstBodyLine, font: NSFont(name: "Times-Roman", size: 13)!, baseline: 300)
        draw(secondBodyLine, font: NSFont(name: "Times-Roman", size: 13)!, baseline: 282)
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage()
        context.closePDF()
        return url
    }

    private static func draw(_ text: String, font: NSFont, baseline: CGFloat) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor.black])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: 40, y: baseline)
        CTLineDraw(line, context)
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Page text editing smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
