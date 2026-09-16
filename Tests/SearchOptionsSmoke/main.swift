import AppKit
import PDFKit

@main
@MainActor
struct SearchOptionsSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-search-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let suiteName = "it.lucalazzaroni.zzpdf.tests.search.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = PDFWorkspace(
            preferences: AppPreferences(defaults: defaults),
            recoveryStore: TemporaryRecoveryStore(directoryURL: directory.appendingPathComponent("Recovery"))
        )
        let view = InteractivePDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
        workspace.pdfView = view
        view.workspace = workspace
        workspace.load(makePDF(in: directory))
        view.document = workspace.pdfDocument

        // Plain search: case-insensitive, matches inside words too.
        workspace.searchText = "Roma"
        workspace.updateSearch()
        check(workspace.isSearching, "The search did not start in the background")
        workspace.waitForSearch()
        check(!workspace.isSearching, "The search never reported that it had finished")
        check(
            workspace.searchResults.count == 4,
            "A plain search found \(workspace.searchResults.count) results instead of 4"
        )

        // Matching case drops "romantico" and the all-caps "ROMA".
        workspace.searchMatchesCase = true
        workspace.waitForSearch()
        check(
            workspace.searchResults.count == 2,
            "Matching case found \(workspace.searchResults.count) results instead of 2"
        )

        // Both spellings of the whole word survive; the one inside "romantico" does not.
        workspace.searchMatchesCase = false
        workspace.searchWholeWords = true
        workspace.waitForSearch()
        check(
            workspace.searchResults.count == 3,
            "Whole words found \(workspace.searchResults.count) results instead of 3"
        )

        // Every result knows its page and carries readable context around the match.
        let pages = workspace.searchResults.map { workspace.pageNumber(for: $0) }
        check(pages == pages.sorted(), "Results are not in page order: \(pages)")
        check(Set(pages) == [1, 2], "Results were found on pages \(Set(pages)) instead of 1 and 2")
        for result in workspace.searchResults {
            let snippet = workspace.searchSnippet(for: result)
            check(
                snippet.lowercased().contains("roma"),
                "A result's snippet reads \"\(snippet)\" and does not contain the match"
            )
            check(snippet.count > 4, "The snippet \"\(snippet)\" carries no context around the match")
        }

        // Selecting a result moves the view to it.
        guard let last = workspace.searchResults.last else { fail("No result to show") }
        workspace.showSearchResult(last)
        check(
            workspace.currentPageIndex == workspace.pageNumber(for: last) - 1,
            "Showing a result left the view on page \(workspace.currentPageIndex + 1)"
        )

        // Clearing the field stops the search and empties the list.
        workspace.searchText = ""
        workspace.updateSearch()
        workspace.waitForSearch()
        check(workspace.searchResults.isEmpty, "Clearing the field left results behind")
        check(!workspace.isSearching, "Clearing the field left a search running")

        // A search that matches nothing ends cleanly rather than hanging.
        workspace.searchText = "zzzz-non-esiste"
        workspace.updateSearch()
        workspace.waitForSearch()
        check(workspace.searchResults.isEmpty, "A search for nothing found something")
        check(!workspace.isSearching, "A search for nothing never finished")

        print("Search options smoke test passed.")
    }

    private static func makePDF(in directory: URL) -> URL {
        let url = directory.appendingPathComponent("search.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 420, height: 300)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        let lines: [[String]] = [
            ["Il treno per Roma parte alle otto.", "Un film romantico non e Roma."],
            ["ROMA e scritta tutta maiuscola qui.", "Nessuna occorrenza in questa riga."]
        ]
        for pageLines in lines {
            context.beginPDFPage(nil)
            let font = CTFontCreateWithName("Helvetica" as CFString, 13, nil)
            for (index, line) in pageLines.enumerated() {
                let attributed = NSAttributedString(string: line, attributes: [.font: font])
                context.textPosition = CGPoint(x: 40, y: 220 - Double(index) * 24)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            }
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Search options smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
