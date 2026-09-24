import AppKit
import PDFKit

/// Where a link in a PDF leads.
///
/// Reading this is kept apart from acting on it: what a link points at can then be decided
/// and tested without anything being opened.
enum PDFLinkTarget: Equatable {
    /// Somewhere else in this document.
    case destination(PDFDestination)
    /// A web or mail address, which is what nearly every link in a PDF is.
    case web(URL)
    /// Any other scheme. A PDF can name one that runs something, so these are confirmed
    /// before they are opened rather than handed straight to the system.
    case external(URL)
    /// Another document, optionally at a page.
    case remote(URL, pageIndex: Int?)
    /// One of the viewer commands a PDF can ask for, such as the next page.
    case command(PDFActionNamedName)

    /// The link `annotation` carries, or nil if it carries none.
    ///
    /// A link may describe itself either with an action or with the older `url` and
    /// `destination` properties, and plenty of files in the wild use each.
    static func of(_ annotation: PDFAnnotation) -> PDFLinkTarget? {
        if let target = annotation.action.flatMap(of) { return target }
        if let url = annotation.url { return of(url) }
        if let destination = annotation.destination { return .destination(destination) }
        return nil
    }

    static func of(_ action: PDFAction) -> PDFLinkTarget? {
        if let action = action as? PDFActionURL, let url = action.url { return of(url) }
        if let action = action as? PDFActionGoTo { return .destination(action.destination) }
        if let action = action as? PDFActionRemoteGoTo {
            return .remote(action.url, pageIndex: action.pageIndex)
        }
        if let action = action as? PDFActionNamed { return .command(action.name) }
        return nil
    }

    private static func of(_ url: URL) -> PDFLinkTarget {
        let scheme = url.scheme?.lowercased() ?? ""
        return ["http", "https", "mailto"].contains(scheme) ? .web(url) : .external(url)
    }

    /// What to show the reader before following the link.
    var summary: String {
        switch self {
        case .destination(let destination):
            guard let page = destination.page, let document = page.document else { return "this document" }
            let index = document.index(for: page)
            return index == NSNotFound ? "this document" : "page \(index + 1)"
        case .web(let url), .external(let url):
            return url.absoluteString
        case .remote(let url, let pageIndex):
            let name = url.lastPathComponent
            guard let pageIndex else { return name }
            return "\(name), page \(pageIndex + 1)"
        case .command(let name):
            return name.commandLabel
        }
    }
}

extension PDFActionNamedName {
    var commandLabel: String {
        switch self {
        case .nextPage: return "the next page"
        case .previousPage: return "the previous page"
        case .firstPage: return "the first page"
        case .lastPage: return "the last page"
        case .goBack: return "back"
        case .goForward: return "forward"
        case .goToPage: return "another page"
        case .zoomIn: return "a closer view"
        case .zoomOut: return "a wider view"
        case .find: return "Find"
        case .print: return "Print"
        case .none: return "nothing"
        @unknown default: return "a viewer command"
        }
    }
}
