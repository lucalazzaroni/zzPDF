import AppKit
import PDFKit

/// The Edit Text tool has to set a replacement in the typeface the page is already using.
///
/// PDFKit cannot tell it what that is: for a document typeset with LaTeX it reports the
/// size correctly and then says Helvetica for every run, whatever the page is really set
/// in. The font has to come from the page's own content stream instead.
@main
@MainActor
struct PageFontSmoke {
    static func main() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zzpdf-fonts-smoke-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A serif page whose font is named the way an embedded subset is named: six capitals,
        // a plus sign, and a name that is installed nowhere.
        let url = makePDF(in: directory, named: "NimbusRom9L")
        guard let page = PDFDocument(url: url)?.page(at: 0) else { fail("The fixture has no page") }

        let runs = PageFonts.runs(on: page)
        check(runs.count == 1, "The stream holds \(runs.count) runs of text instead of 1")
        check(
            runs.first?.postScriptName == "AAAAAB+NimbusRom9L",
            "The stream names the font \(runs.first?.postScriptName ?? "nothing")"
        )

        // The run is found by where it is drawn, and its size comes from the caller, because
        // that is the one thing PDFKit does report faithfully.
        guard let selection = page.selection(for: page.bounds(for: .cropBox)),
              selection.string?.isEmpty == false else {
            fail("The fixture's text could not be selected")
        }
        let bounds = selection.bounds(for: page)
        guard let matched = PageFonts.run(on: page, near: bounds) else {
            fail("No run was found at \(bounds), where the fixture draws its line")
        }
        check(
            abs(matched.origin.x - bounds.minX) < 1,
            "The matched run starts at \(matched.origin.x) but the line at \(bounds.minX)"
        )
        guard let font = PageFonts.font(on: page, near: bounds, size: 14) else {
            fail("The page's font could not be resolved")
        }
        check(
            font.familyName == "Times New Roman",
            "A serif page resolved to \(font.familyName ?? "nil") instead of Times New Roman"
        )
        check(abs(font.pointSize - 14) < 0.01, "The font came back at \(font.pointSize)pt instead of 14")

        // Nothing is drawn far from the text, so nothing is claimed to be there.
        let elsewhere = CGRect(x: 30, y: 20, width: 100, height: 12)
        check(
            PageFonts.run(on: page, near: elsewhere) == nil,
            "A run was found at \(elsewhere), where the fixture draws nothing"
        )

        // The names LaTeX and Word actually write, read for what they say. None of these are
        // installed, so every one of them would otherwise come back as Helvetica.
        expect("KASYJM+CMBX12", family: "Times New Roman", bold: true)     // Computer Modern bold
        expect("ASQKYX+CMR10", family: "Times New Roman", bold: false)     // Computer Modern roman
        expect("MDPSPY+CMTT9", family: "Courier New", bold: false)         // Computer Modern typewriter
        expect("ABCDEF+CMSS10", family: "Helvetica", bold: false)          // Computer Modern sans
        expect("LOFSUD+LMRoman12-Bold", family: "Times New Roman", bold: true)
        expect("HZGPHI+NimbusRomNo9L-Regu", family: "Times New Roman", bold: false)
        expect("ENXHQB+NimbusMonL-Regu", family: "Courier New", bold: false)
        expect("BCDEEE+Calibri-Bold", family: "Helvetica", bold: true)
        expect("AZCCVO+SFRM1000", family: "Times New Roman", bold: false)

        // A font that is installed is used as it is, rather than being mapped to a stand-in.
        let real = PDFFontResolver.font(postScriptName: "Times-Roman", traits: PageFonts.Traits(), size: 12)
        check(real.fontName == "Times-Roman", "An installed font was swapped for \(real.fontName)")

        // When the name says nothing, the PDF's own descriptor is believed.
        var serif = PageFonts.Traits()
        serif.serif = true
        let unnamed = PDFFontResolver.font(postScriptName: "ABCDEF+Unknown", traits: serif, size: 12)
        check(
            unnamed.familyName == "Times New Roman",
            "A font flagged serif in the PDF came back as \(unnamed.familyName ?? "nil")"
        )

        print("Page font smoke test passed.")
    }

    private static func expect(_ name: String, family: String, bold: Bool) {
        let font = PDFFontResolver.font(postScriptName: name, traits: PageFonts.Traits(), size: 12)
        check(font.familyName == family, "\(name) resolved to \(font.familyName ?? "nil") instead of \(family)")
        let isBold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
        check(isBold == bold, "\(name) came back \(isBold ? "bold" : "regular")")
    }

    /// A one-line PDF whose font carries `name` under a subset prefix.
    ///
    /// Core Graphics embeds the font it is given and names it `AAAAAB+Times-Roman`; renaming
    /// it in place, to a name of exactly the same length, leaves every byte offset in the
    /// file intact while making the font one that no Mac has.
    private static func makePDF(in directory: URL, named name: String) -> URL {
        let url = directory.appendingPathComponent("subset.pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 300, height: 200)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, nil) else {
            fail("The test PDF context could not be created")
        }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Times-Roman" as CFString, 14, nil)
        let line = NSAttributedString(string: "Riga di prova serif", attributes: [.font: font])
        context.textPosition = CGPoint(x: 30, y: 120)
        CTLineDraw(CTLineCreateWithAttributedString(line), context)
        context.endPDFPage()
        context.closePDF()

        guard name.utf8.count == "Times-Roman".utf8.count else {
            fail("The stand-in name must be as long as Times-Roman to keep the file's offsets")
        }
        guard var data = try? Data(contentsOf: url) else { fail("The fixture could not be read back") }
        let original = Array("Times-Roman".utf8)
        let replacement = Array(name.utf8)
        var replaced = 0
        var index = 0
        while index + original.count <= data.count {
            if Array(data[index..<(index + original.count)]) == original {
                data.replaceSubrange(index..<(index + original.count), with: replacement)
                replaced += 1
                index += original.count
            } else {
                index += 1
            }
        }
        check(replaced > 0, "The fixture does not name its font Times-Roman")
        try! data.write(to: url)
        return url
    }

    private static func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        guard condition else { fail(message()) }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("Page font smoke test failed: \(message)\n".utf8))
        exit(1)
    }
}
