import AppKit
import PDFKit

/// What a page's content stream says its text is actually set in.
///
/// PDFKit's own `attributedString` is no help here. For a document typeset with LaTeX —
/// Computer Modern, Nimbus Roman, anything embedded as Type 1 — it reports the right size
/// but hands back Helvetica for every run, because it cannot map the embedded program to a
/// font on this Mac. Replacing a line with what PDFKit claimed left one serif paragraph
/// with a line of sans in the middle of it.
///
/// The page's own content stream does know: every run of text is preceded by a `Tf` naming
/// a font in the page's resources, and that font carries its real PostScript name. Reading
/// the stream is the only way to find out what a line is set in.
enum PageFonts {
    /// One text-showing operator, with the font in force and where it starts in user space.
    struct Run {
        let postScriptName: String
        let traits: Traits
        let origin: CGPoint
        let size: CGFloat
    }

    /// What the PDF's font descriptor says about the typeface, when it says anything.
    struct Traits {
        var serif: Bool?
        var fixedPitch: Bool?
        var italic: Bool?
        var bold: Bool?
    }

    /// The font the page draws the text at `bounds` in, at `size` points, or nil if the
    /// stream cannot be read or has no text anywhere near.
    ///
    /// `bounds` is in PDFKit page coordinates; the crop box's origin is added back to reach
    /// the user space the content stream is written in.
    static func font(on page: PDFPage, near bounds: CGRect, size: CGFloat) -> NSFont? {
        guard let run = run(on: page, near: bounds) else { return nil }
        return PDFFontResolver.font(postScriptName: run.postScriptName, traits: run.traits, size: size)
    }

    /// The run of text the page draws at `bounds`, or nil if the stream cannot be read or
    /// draws nothing near there.
    ///
    /// `bounds` is in PDFKit page coordinates; the crop box's origin is added back to reach
    /// the user space the content stream is written in.
    static func run(on page: PDFPage, near bounds: CGRect) -> Run? {
        let runs = runs(on: page)
        guard !runs.isEmpty else { return nil }

        let origin = page.bounds(for: .cropBox).origin
        let target = CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y)
        // A run's origin sits on the baseline, which is a little above the bottom of the
        // bounds PDFKit reports; anything within the line's own height is on that line.
        let reach = max(bounds.height, 4)

        let onLine = runs.filter { abs($0.origin.y - target.y) <= reach * 0.8 }
        guard !onLine.isEmpty else { return nil }
        // Several runs share a baseline when a line changes font part way. The one that
        // starts at the left edge of the selection is the one being replaced.
        return onLine.min { abs($0.origin.x - target.x) < abs($1.origin.x - target.x) }
    }

    /// Every text-showing operator on the page, in the order the stream draws them.
    static func runs(on page: PDFPage) -> [Run] {
        guard let cgPage = page.pageRef else { return [] }
        let state = ScanState(fonts: fontTable(of: cgPage))
        let stream = CGPDFContentStreamCreateWithPage(cgPage)

        let table = CGPDFOperatorTableCreate()!
        defer { CGPDFOperatorTableRelease(table) }
        install(table)

        let info = Unmanaged.passUnretained(state).toOpaque()
        let scanner = CGPDFScannerCreate(stream, table, info)
        CGPDFScannerScan(scanner)
        CGPDFScannerRelease(scanner)
        CGPDFContentStreamRelease(stream)
        return state.runs
    }

    // MARK: - Reading the page's font resources

    private static func fontTable(of page: CGPDFPage) -> [String: (name: String, traits: Traits)] {
        guard let dictionary = page.dictionary else { return [:] }
        var resources: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(dictionary, "Resources", &resources), let resources else { return [:] }
        var fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [:] }

        let box = FontTableBox()
        CGPDFDictionaryApplyFunction(fonts, { key, object, info in
            let box = Unmanaged<FontTableBox>.fromOpaque(info!).takeUnretainedValue()
            var font: CGPDFDictionaryRef?
            guard CGPDFObjectGetValue(object, .dictionary, &font), let font else { return }
            box.table[String(cString: key)] = describeFont(font)
        }, Unmanaged.passUnretained(box).toOpaque())
        return box.table
    }

    fileprivate static func describe(font: CGPDFDictionaryRef) -> (name: String, traits: Traits) {
        var base: UnsafePointer<Int8>?
        var name = ""
        if CGPDFDictionaryGetName(font, "BaseFont", &base), let base { name = String(cString: base) }

        // A Type 0 font keeps its descriptor one level down, on the font it delegates to.
        var descriptorHolder: CGPDFDictionaryRef? = font
        var descendants: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(font, "DescendantFonts", &descendants), let descendants,
           CGPDFArrayGetCount(descendants) > 0 {
            var descendant: CGPDFDictionaryRef?
            if CGPDFArrayGetDictionary(descendants, 0, &descendant) { descriptorHolder = descendant }
        }

        var traits = Traits()
        var descriptor: CGPDFDictionaryRef?
        if let holder = descriptorHolder,
           CGPDFDictionaryGetDictionary(holder, "FontDescriptor", &descriptor), let descriptor {
            var flags: CGPDFInteger = 0
            if CGPDFDictionaryGetInteger(descriptor, "Flags", &flags) {
                traits.fixedPitch = flags & 1 != 0
                traits.serif = flags & 2 != 0
                traits.italic = flags & 64 != 0
                if flags & (1 << 18) != 0 { traits.bold = true }
            }
            var angle: CGPDFReal = 0
            if CGPDFDictionaryGetNumber(descriptor, "ItalicAngle", &angle), angle != 0 { traits.italic = true }
            var weight: CGPDFReal = 0
            if traits.bold != true, CGPDFDictionaryGetNumber(descriptor, "StemV", &weight), weight >= 120 {
                traits.bold = true
            }
        }
        return (name, traits)
    }

    // MARK: - Walking the content stream

    private static func install(_ table: CGPDFOperatorTableRef) {
        CGPDFOperatorTableSetCallback(table, "q") { _, info in
            let s = scanState(info); s.stack.append(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "Q") { _, info in
            let s = scanState(info); if let last = s.stack.popLast() { s.ctm = last }
        }
        CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
            let s = scanState(info)
            guard let v = popNumbers(scanner, 6) else { return }
            s.ctm = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5]).concatenating(s.ctm)
        }
        CGPDFOperatorTableSetCallback(table, "BT") { _, info in
            let s = scanState(info); s.text = .identity; s.line = .identity
        }
        CGPDFOperatorTableSetCallback(table, "Tm") { scanner, info in
            let s = scanState(info)
            guard let v = popNumbers(scanner, 6) else { return }
            s.line = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            s.text = s.line
        }
        CGPDFOperatorTableSetCallback(table, "Td") { scanner, info in
            let s = scanState(info)
            guard let v = popNumbers(scanner, 2) else { return }
            s.line = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(s.line)
            s.text = s.line
        }
        CGPDFOperatorTableSetCallback(table, "TD") { scanner, info in
            let s = scanState(info)
            guard let v = popNumbers(scanner, 2) else { return }
            s.leading = -v[1]
            s.line = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(s.line)
            s.text = s.line
        }
        CGPDFOperatorTableSetCallback(table, "TL") { scanner, info in
            let s = scanState(info)
            guard let v = popNumbers(scanner, 1) else { return }
            s.leading = v[0]
        }
        CGPDFOperatorTableSetCallback(table, "T*") { _, info in
            let s = scanState(info)
            s.line = CGAffineTransform(translationX: 0, y: -s.leading).concatenating(s.line)
            s.text = s.line
        }
        CGPDFOperatorTableSetCallback(table, "Tf") { scanner, info in
            let s = scanState(info)
            var size: CGPDFReal = 0
            guard CGPDFScannerPopNumber(scanner, &size) else { return }
            var name: UnsafePointer<Int8>?
            guard CGPDFScannerPopName(scanner, &name), let name else { return }
            s.size = CGFloat(size)
            s.resource = String(cString: name)
        }
        for operatorName in ["Tj", "TJ", "'", "\""] {
            CGPDFOperatorTableSetCallback(table, operatorName) { _, info in
                let s = scanState(info)
                // A quote operator moves to the next line before it draws.
                s.show()
            }
        }
    }
}

private final class ScanState {
    let fonts: [String: (name: String, traits: PageFonts.Traits)]
    var runs: [PageFonts.Run] = []

    var ctm = CGAffineTransform.identity
    var stack: [CGAffineTransform] = []
    var text = CGAffineTransform.identity
    var line = CGAffineTransform.identity
    var leading: CGFloat = 0
    var resource: String?
    var size: CGFloat = 0

    init(fonts: [String: (name: String, traits: PageFonts.Traits)]) { self.fonts = fonts }

    func show() {
        guard let resource, let font = fonts[resource] else { return }
        let combined = text.concatenating(ctm)
        let origin = CGPoint(x: combined.tx, y: combined.ty)
        let scale = sqrt(abs(combined.a * combined.d - combined.b * combined.c))
        runs.append(PageFonts.Run(
            postScriptName: font.name,
            traits: font.traits,
            origin: origin,
            size: size * (scale > 0 ? scale : 1)
        ))
    }
}


private final class FontTableBox {
    var table: [String: (name: String, traits: PageFonts.Traits)] = [:]
}

private func describeFont(_ font: CGPDFDictionaryRef) -> (name: String, traits: PageFonts.Traits) {
    PageFonts.describe(font: font)
}

private func scanState(_ info: UnsafeMutableRawPointer?) -> ScanState {
    Unmanaged<ScanState>.fromOpaque(info!).takeUnretainedValue()
}

/// Operands come off the stack last one first; this hands them back in written order.
private func popNumbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values: [CGFloat] = []
    for _ in 0..<count {
        var value: CGPDFReal = 0
        guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
        values.append(CGFloat(value))
    }
    return values.reversed()
}

/// Finds a font on this Mac that stands in for one embedded in a PDF.
///
/// A PDF carries its fonts inside itself, usually cut down to the glyphs it uses and
/// renamed — `ABCDEF+NimbusRomNo9L-Regu`, `CMR10`, and so on. Nothing by those names is
/// installed, so the name has to be read for what it says about the typeface.
enum PDFFontResolver {
    /// The closest installed font to the one a PDF calls `postScriptName`.
    static func font(postScriptName: String, traits: PageFonts.Traits, size: CGFloat) -> NSFont {
        let size = max(1, size)
        let name = stripSubsetPrefix(postScriptName)
        if let exact = NSFont(name: name, size: size) { return exact }
        if let exact = NSFont(name: postScriptName, size: size) { return exact }
        // "Times New Roman,Bold" and "TimesNewRomanPS-BoldMT" both name a family and a style.
        if let comma = name.firstIndex(of: ","), let family = NSFont(name: String(name[..<comma]), size: size) {
            return styled(family, bold: name.lowercased().contains("bold"),
                          italic: name.lowercased().contains("italic"), size: size)
        }
        return substitute(named: name, traits: traits, size: size)
    }

    /// The same, for a font PDFKit handed back — used when the page's stream cannot be read.
    static func installedCounterpart(of font: NSFont) -> NSFont {
        if NSFont(name: font.fontName, size: font.pointSize) != nil { return font }
        return self.font(postScriptName: font.fontName, traits: PageFonts.Traits(), size: font.pointSize)
    }

    private static func stripSubsetPrefix(_ name: String) -> String {
        guard let plus = name.firstIndex(of: "+"), name.distance(from: name.startIndex, to: plus) == 6 else {
            return name
        }
        return String(name[name.index(after: plus)...])
    }

    /// Reads what the name and the PDF's own descriptor say, and picks the nearest match.
    private static func substitute(named name: String, traits: PageFonts.Traits, size: CGFloat) -> NSFont {
        let lowered = name.lowercased()
        let bold = traits.bold ?? false
            || lowered.contains("bold") || lowered.contains("black") || lowered.contains("heavy")
            || lowered.contains("-bd") || lowered.contains("bx") || lowered.contains("medi")
        let italic = traits.italic ?? false
            || lowered.contains("italic") || lowered.contains("oblique") || lowered.contains("-it")
            || lowered.contains("ti") && lowered.hasPrefix("cm")

        // The name is the better witness. A PDF's descriptor flags are often only
        // "symbolic" for an embedded subset — every Computer Modern face says that — so
        // going by the flags first turns a LaTeX paper's serif into Helvetica.
        let mono = ["mono", "courier", "consol", "menlo", "typewriter", "nimbusmon"]
        let sans = ["helvetica", "arial", "verdana", "tahoma", "calibri", "futura",
                    "gothic", "aptos", "segoe", "nimbussan", "lato", "roboto", "opensans"]
        let serif = ["times", "roman", "serif", "georgia", "garamond", "minion", "palatino",
                     "century", "nimbusrom", "cambria", "charter", "book", "utopia", "libertine"]

        // LaTeX names its faces by abbreviation: cmr/cmbx/cmti are Computer Modern's
        // roman, cmss its sans, cmtt its typewriter; lm* and sf* are the same scheme.
        let latexMono = ["cmtt", "sftt", "lmmono"]
        let latexSans = ["cmss", "sfss", "lmsans"]
        let latexSerif = ["cmr", "cmb", "cmti", "cmmi", "cmcsc", "cmex", "cmsy",
                          "sfrm", "sfbx", "sfti", "lmroman", "rmtmi", "rtcx"]

        let family: String
        if latexMono.contains(where: lowered.hasPrefix) || mono.contains(where: lowered.contains) {
            family = "Courier New"
        } else if latexSans.contains(where: lowered.hasPrefix) || sans.contains(where: lowered.contains) {
            family = "Helvetica"
        } else if latexSerif.contains(where: lowered.hasPrefix) || serif.contains(where: lowered.contains) {
            family = "Times New Roman"
        } else if traits.fixedPitch == true {
            family = "Courier New"
        } else if traits.serif == true {
            family = "Times New Roman"
        } else {
            family = "Helvetica"
        }

        let base = NSFont(name: family, size: size) ?? .systemFont(ofSize: size)
        return styled(base, bold: bold, italic: italic, size: size)
    }

    private static func styled(_ font: NSFont, bold: Bool, italic: Bool, size: CGFloat) -> NSFont {
        guard bold || italic, let family = font.familyName else { return font }
        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        return NSFontManager.shared.font(
            withFamily: family,
            traits: traits,
            weight: bold ? 9 : 5,
            size: size
        ) ?? font
    }
}
