import AppKit
import PDFKit

/// Opening a document that is already on screen, and following the links in one.
@main
@MainActor
struct OpenAndLinkSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-open-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        openRequests(in: directory)
        links(in: directory)
        print("Open request and link smoke test passed.")
    }

    // MARK: - Where an open request goes

    private static func openRequests(in directory: URL) {
        let first = directory.appendingPathComponent("uno.pdf")
        let second = directory.appendingPathComponent("due.pdf")
        typealias Candidate = WorkspaceRegistry.Candidate

        // Nothing open yet: the document needs a window of its own.
        check(
            WorkspaceRegistry.outcome(for: first, among: []) == .newWindow,
            "With no windows the document did not ask for one"
        )

        // An empty window takes it rather than a new one being opened.
        check(
            WorkspaceRegistry.outcome(for: first, among: [Candidate(url: nil, isEmpty: true)]) == .loadInto(0),
            "An empty window was passed over"
        )

        // The one that was going wrong: at launch the window restoring last session's
        // document and the file being opened are the same file, and a second window opened
        // on top of it. It has to be brought forward instead.
        let restored = [Candidate(url: first, isEmpty: false)]
        check(
            WorkspaceRegistry.outcome(for: first, among: restored) == .front(0),
            "Opening a document already on screen did not bring its window forward"
        )

        // The same file named differently is still the same file.
        let awkward = directory.appendingPathComponent("./uno.pdf")
        check(
            WorkspaceRegistry.outcome(for: awkward, among: restored) == .front(0),
            "\(awkward.path) was not recognised as \(first.path)"
        )

        // A different document does open its own window, and does not land on top of one
        // that is already showing something.
        check(
            WorkspaceRegistry.outcome(for: second, among: restored) == .newWindow,
            "A second document did not get its own window"
        )

        // The window already showing it wins over an empty one.
        let mixed = [Candidate(url: nil, isEmpty: true), Candidate(url: first, isEmpty: false)]
        check(
            WorkspaceRegistry.outcome(for: first, among: mixed) == .front(1),
            "An empty window was filled although the document was already open"
        )
    }

    // MARK: - Following a link

    private static func links(in directory: URL) {
        let url = makePDF(in: directory)
        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            fail("The fixture has no page")
        }
        // A link into the document is made here rather than in the fixture: a destination
        // does not come back from a file pointing at the reopened document's own pages.
        guard let second = document.page(at: 1) else { fail("The fixture has only one page") }
        let inner = PDFAnnotation(bounds: CGRect(x: 40, y: 70, width: 120, height: 20), forType: .link, withProperties: nil)
        inner.action = PDFActionGoTo(destination: PDFDestination(page: second, at: CGPoint(x: 0, y: 200)))
        page.addAnnotation(inner)

        let links = page.annotations.filter { $0.isSubtype(.link) }
        check(links.count == 3, "The fixture holds \(links.count) links instead of 3")

        // A web address is followed without asking. Anything else is not, because a PDF can
        // name a scheme that runs something.
        guard let web = target(of: links, at: CGPoint(x: 60, y: 160)) else { fail("The web link was not read") }
        check(web == .web(URL(string: "https://example.org/paper")!), "The web link reads as \(web)")
        check(web.summary == "https://example.org/paper", "The web link is described as \(web.summary)")

        guard let odd = target(of: links, at: CGPoint(x: 60, y: 120)) else { fail("The other link was not read") }
        guard case .external(let oddURL) = odd else { fail("A file link reads as \(odd) rather than external") }
        check(oddURL.scheme == "file", "The external link points at \(oddURL)")

        // A link into the document itself is a destination, described by its page number.
        guard let inside = target(of: links, at: CGPoint(x: 60, y: 80)) else { fail("The inner link was not read") }
        guard case .destination(let destination) = inside else { fail("An inner link reads as \(inside)") }
        let destinationIndex = destination.page.map { document.index(for: $0) } ?? NSNotFound
        check(destinationIndex == 1, "The inner link goes to page index \(destinationIndex) instead of 1")
        check(inside.summary == "page 2", "The inner link is described as \(inside.summary)")

        // The canvas finds a link under the pointer, and finds nothing where there is none.
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 400, height: 500))
        view.document = document
        view.layoutSubtreeIfNeeded()
        let onLink = view.convert(CGPoint(x: 60, y: 160), from: page)
        check(view.link(at: onLink) != nil, "The canvas found no link where the fixture draws one")
        let empty = view.convert(CGPoint(x: 260, y: 300), from: page)
        check(view.link(at: empty) == nil, "The canvas found a link where the fixture draws none")

        // An annotation that is not a link has nothing to follow.
        let note = PDFAnnotation(bounds: CGRect(x: 10, y: 10, width: 20, height: 20), forType: .text, withProperties: nil)
        check(PDFLinkTarget.of(note) == nil, "A note was read as a link")
    }

    private static func target(of links: [PDFAnnotation], at point: CGPoint) -> PDFLinkTarget? {
        guard let link = links.first(where: { $0.bounds.contains(point) }) else { return nil }
        return PDFLinkTarget.of(link)
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("links.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        for index in 0..<2 {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 12, nil)
            let line = NSAttributedString(string: "Pagina \(index + 1)", attributes: [.font: font])
            context.textPosition = CGPoint(x: 40, y: 40)
            CTLineDraw(CTLineCreateWithAttributedString(line), context)
            context.endPDFPage()
        }
        context.closePDF()

        guard let document = PDFDocument(url: url), let page = document.page(at: 0) else {
            fail("The fixture could not be read back")
        }
        page.addAnnotation(link(CGRect(x: 40, y: 150, width: 120, height: 20),
                                to: URL(string: "https://example.org/paper")!))
        page.addAnnotation(link(CGRect(x: 40, y: 110, width: 120, height: 20),
                                to: URL(fileURLWithPath: "/tmp/altro.pdf")))
        document.write(to: url)
        return url
    }

    private static func link(_ bounds: CGRect, to url: URL) -> PDFAnnotation {
        let annotation = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        annotation.action = PDFActionURL(url: url)
        return annotation
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Open request and link smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
