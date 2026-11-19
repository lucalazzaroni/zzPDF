import AppKit
import PDFKit

/// Reading a reviewer's comments.
///
/// Someone commenting on a passage in Acrobat or Word leaves a highlight with the comment
/// in its text, behind a popup that starts closed. PDFKit reads it, but nothing in the app
/// showed it: clicking the highlight said only that an annotation was selected, so a paper
/// sent back with fifty comments looked like a paper with fifty yellow stripes.
@main
@MainActor
struct CommentSmoke {
    static func main() {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-comments-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let suiteName = "it.lucalazzaroni.zzpdf.tests.comments.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("R"))
        )
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        let view = InteractivePDFView(frame: NSRect(x: 0, y: 0, width: 500, height: 500))
        window.contentView = view
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makeReviewedPDF(in: directory))
        view.document = workspace.pdfDocument
        view.autoScales = false
        view.scaleFactor = 1
        view.layoutDocumentView()
        guard let page = workspace.pdfDocument?.page(at: 0) else { fail("The fixture has no page") }
        let highlights = page.annotations.filter { $0.isSubtype(.highlight) }
        guard highlights.count == 2,
              let commented = highlights.first(where: { !($0.contents ?? "").isEmpty }),
              let bare = highlights.first(where: { ($0.contents ?? "").isEmpty }) else {
            fail("The fixture should hold one commented and one bare highlight, not \(highlights.count)")
        }

        // The comment is found on the highlight that has one, and only there.
        check(workspace.comment(on: commented) == "Not clear. What do you mean?",
              "The comment read as \(workspace.comment(on: commented) ?? "nothing")")
        check(workspace.comment(on: bare) == nil, "A highlight without a comment was given one")

        // Resting the pointer on it shows the comment and who left it.
        let centre = view.convert(CGPoint(x: commented.bounds.midX, y: commented.bounds.midY), from: page)
        check(view.commentTip(at: centre) == "Reviewer: Not clear. What do you mean?",
              "Resting on the highlight showed \(view.commentTip(at: centre) ?? "nothing")")
        let bareCentre = view.convert(CGPoint(x: bare.bounds.midX, y: bare.bounds.midY), from: page)
        check(view.commentTip(at: bareCentre) == nil, "Resting on a highlight with no comment showed one")

        // The sidebar lists it by what it says.
        check(workspace.annotationEntries().contains { $0.summary == "Not clear. What do you mean?" },
              "The sidebar does not list the comment")

        // Selecting it puts the comment in the inspector, where it can be answered. A run
        // of typing is one undo step.
        workspace.selectAnnotation(commented)
        check(workspace.selectedAnnotationTakesComment, "A selected highlight was not offered a comment")
        check(workspace.selectedCommentText == "Not clear. What do you mean?", "The inspector shows \(workspace.selectedCommentText)")
        check(workspace.selectedCommentAttribution?.hasPrefix("Reviewer") == true, "The inspector does not say who commented")
        workspace.setSelectedComment("Not clear. What do you mean? —")
        workspace.setSelectedComment("Not clear. What do you mean? — Rephrased")
        workspace.setSelectedComment("Not clear. What do you mean? — Rephrased in 3.2")
        check(commented.contents == "Not clear. What do you mean? — Rephrased in 3.2", "The answer was not written")
        workspace.undo()
        check(commented.contents == "Not clear. What do you mean?", "One undo did not take the typing back: \(commented.contents ?? "")")
        workspace.redo()

        // The answer survives being saved.
        let saved = directory.appendingPathComponent("risposto.pdf")
        check(workspace.pdfDocument?.write(to: saved) == true, "The document could not be saved")
        guard let reopened = PDFDocument(url: saved),
              let reopenedHighlight = reopened.page(at: 0)?.annotations.first(where: {
                  $0.isSubtype(.highlight) && !($0.contents ?? "").isEmpty
              }) else { fail("The saved file lost the commented highlight") }
        check(reopenedHighlight.contents == "Not clear. What do you mean? — Rephrased in 3.2",
              "The saved comment reads \(reopenedHighlight.contents ?? "nothing")")

        // A note is its own text and a redaction is not a comment.
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        note.contents = "Una nota"
        check(!workspace.takesComment(note), "A note was offered a second comment")
        let redaction = PDFAnnotation(bounds: CGRect(x: 10, y: 40, width: 20, height: 20), forType: .square, withProperties: nil)
        redaction.contents = RedactionFlattener.marker
        check(workspace.comment(on: redaction) == nil, "A redaction's marker was shown as a comment")

        print("Comment smoke test passed.")
    }

    /// A page of text with two highlights, the way a reviewer returns it: one with a comment,
    /// an author and a closed popup, one with nothing to say.
    private static func makeReviewedPDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("da-rivedere.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else { fail("No PDF context") }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Times-Roman" as CFString, 12, nil)
        for (text, y) in [("The method quantises the weights.", 340), ("Results are shown in Table 2.", 300)] {
            context.textPosition = CGPoint(x: 24, y: CGFloat(y))
            CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font])), context)
        }
        context.endPDFPage()
        context.closePDF()

        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else { fail("No fixture page") }
        for (y, comment) in [(336.0, "Not clear. What do you mean?"), (296.0, "")] {
            let bounds = CGRect(x: 22, y: y, width: 190, height: 16)
            let highlight = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            highlight.color = .yellow
            highlight.quadrilateralPoints = [
                NSValue(point: CGPoint(x: 0, y: bounds.height)), NSValue(point: CGPoint(x: bounds.width, y: bounds.height)),
                NSValue(point: CGPoint(x: 0, y: 0)), NSValue(point: CGPoint(x: bounds.width, y: 0))
            ]
            if !comment.isEmpty {
                highlight.contents = comment
                highlight.userName = "Reviewer"
                let popup = PDFAnnotation(bounds: CGRect(x: 220, y: y - 60, width: 70, height: 60), forType: .popup, withProperties: nil)
                popup.isOpen = false
                highlight.popup = popup
                page.addAnnotation(popup)
            }
            page.addAnnotation(highlight)
        }
        document.write(to: url)
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Comment smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
