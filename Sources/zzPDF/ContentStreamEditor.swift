import AppKit
import PDFKit

/// Takes text back out of a page's content stream.
///
/// Painting a rectangle over a line hides it and no more: the glyphs are still in the page,
/// so Find still turns them up, copying still yields them, and — since the replacement sits
/// exactly on top of them — what comes back out is the old line and the new one shuffled
/// together, one character each. Removing the text means editing the stream that draws it.
///
/// Nothing is deleted: a show operator keeps its place and loses its string. The operators
/// that move the pen stay exactly as they were, so everything after the removed run is
/// still drawn where it always was.
enum ContentStreamEditor {
    /// A copy of `pdf` with the text drawn inside `rects` removed, or nil if the file is
    /// not one this can safely edit — in which case the caller keeps what it had.
    ///
    /// `rects` are in the page's own default user space, which is the space the generated
    /// stream is written in.
    static func removingText(inside rects: [CGRect], from pdf: Data) -> Data? {
        guard !rects.isEmpty else { return nil }
        guard let contents = contentsObject(in: pdf) else { return nil }
        guard let stream = decodedContentStream(of: pdf) else { return nil }

        let edited = removingText(inside: rects, fromStream: stream)
        guard edited != stream else { return nil }
        return appendingUpdate(object: contents, stream: edited, to: pdf)
    }

    // MARK: - The stream itself

    /// The same stream with every run of text drawn inside `rects` emptied.
    static func removingText(inside rects: [CGRect], fromStream stream: Data) -> Data {
        let bytes = [UInt8](stream)
        var scanner = Scanner(bytes: bytes)
        var state = TextState()
        var operands: [Item] = []
        var blanks: [(range: Range<Int>, replacement: [UInt8])] = []
        var needsTextPosition = false

        while let item = scanner.next() {
            guard case .operatorName(let name) = item.kind else {
                operands.append(item)
                continue
            }
            switch name {
            case "q": state.stack.append(state.ctm)
            case "Q": if let last = state.stack.popLast() { state.ctm = last }
            case "cm":
                if let m = matrix(from: operands, bytes: bytes) { state.ctm = m.concatenating(state.ctm) }
            case "BT":
                state.text = .identity; state.line = .identity
                needsTextPosition = false
            case "Tm":
                if let m = matrix(from: operands, bytes: bytes) {
                    state.line = m; state.text = m
                    needsTextPosition = false
                }
            case "Td":
                if let v = numbers(from: operands, bytes: bytes, count: 2) {
                    state.line = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(state.line)
                    state.text = state.line
                    needsTextPosition = false
                }
            case "TD":
                if let v = numbers(from: operands, bytes: bytes, count: 2) {
                    state.leading = -v[1]
                    state.line = CGAffineTransform(translationX: v[0], y: v[1]).concatenating(state.line)
                    state.text = state.line
                    needsTextPosition = false
                }
            case "TL":
                if let v = numbers(from: operands, bytes: bytes, count: 1) { state.leading = v[0] }
            case "T*":
                state.line = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(state.line)
                state.text = state.line
                needsTextPosition = false
            case "Tj", "TJ", "'", "\"":
                if name == "'" || name == "\"" {
                    // Both move to the next line before drawing.
                    state.line = CGAffineTransform(translationX: 0, y: -state.leading).concatenating(state.line)
                    state.text = state.line
                    needsTextPosition = false
                }
                // A show operator advances by font-specific glyph widths. This parser
                // does not resolve those widths. Guessing the next origin, or erasing
                // the previous advance, can remove/move unrelated text. Keep the
                // complete stream unchanged and let the writer use its visual cover.
                guard !needsTextPosition else { return stream }
                let combined = state.text.concatenating(state.ctm)
                let origin = CGPoint(x: combined.tx, y: combined.ty)
                if rects.contains(where: { $0.contains(origin) }),
                   let target = drawnOperand(of: name, in: operands) {
                    blanks.append((target.range, target.isArray ? Array("[]".utf8) : Array("()".utf8)))
                }
                needsTextPosition = true
            default: break
            }
            operands.removeAll(keepingCapacity: true)
        }

        guard !blanks.isEmpty else { return stream }
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var cursor = 0
        for blank in blanks.sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
            guard blank.range.lowerBound >= cursor else { continue }
            output.append(contentsOf: bytes[cursor..<blank.range.lowerBound])
            output.append(contentsOf: blank.replacement)
            cursor = blank.range.upperBound
        }
        output.append(contentsOf: bytes[cursor...])
        return Data(output)
    }

    /// The operand a show operator draws: the string, or the array for `TJ`.
    private static func drawnOperand(
        of name: String,
        in operands: [Item]
    ) -> (range: Range<Int>, isArray: Bool)? {
        guard let last = operands.last else { return nil }
        switch name {
        case "TJ":
            guard case .array = last.kind else { return nil }
            return (last.range, true)
        case "\"":
            // aw ac string "
            guard case .string = last.kind else { return nil }
            return (last.range, false)
        default:
            guard case .string = last.kind else { return nil }
            return (last.range, false)
        }
    }

    private struct TextState {
        var ctm = CGAffineTransform.identity
        var stack: [CGAffineTransform] = []
        var text = CGAffineTransform.identity
        var line = CGAffineTransform.identity
        var leading: CGFloat = 0
    }

    private static func numbers(from operands: [Item], bytes: [UInt8], count: Int) -> [CGFloat]? {
        let numeric = operands.compactMap { item -> CGFloat? in
            guard case .number(let value) = item.kind else { return nil }
            return value
        }
        guard numeric.count >= count else { return nil }
        return Array(numeric.suffix(count))
    }

    private static func matrix(from operands: [Item], bytes: [UInt8]) -> CGAffineTransform? {
        guard let v = numbers(from: operands, bytes: bytes, count: 6) else { return nil }
        return CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
    }

    // MARK: - Tokens

    struct Item {
        enum Kind {
            case number(CGFloat)
            case string
            case array
            case dictionary
            case name
            case operatorName(String)
            case inlineImage
        }
        let range: Range<Int>
        let kind: Kind
    }

    /// Walks a content stream token by token, remembering where each one sits so it can be
    /// put back untouched.
    struct Scanner {
        let bytes: [UInt8]
        var index = 0

        init(bytes: [UInt8]) { self.bytes = bytes }

        private static let whitespace: Set<UInt8> = [0x00, 0x09, 0x0A, 0x0C, 0x0D, 0x20]
        private static let delimiters: Set<UInt8> = [0x28, 0x29, 0x3C, 0x3E, 0x5B, 0x5D, 0x7B, 0x7D, 0x2F, 0x25]

        mutating func next() -> Item? {
            skipBlanks()
            guard index < bytes.count else { return nil }
            let start = index
            switch bytes[index] {
            case 0x28: // (
                skipLiteralString()
                return Item(range: start..<index, kind: .string)
            case 0x3C: // < or <<
                if index + 1 < bytes.count, bytes[index + 1] == 0x3C {
                    skipNested(open: (0x3C, 0x3C), close: (0x3E, 0x3E))
                    return Item(range: start..<index, kind: .dictionary)
                }
                while index < bytes.count, bytes[index] != 0x3E { index += 1 }
                if index < bytes.count { index += 1 }
                return Item(range: start..<index, kind: .string)
            case 0x5B: // [
                skipArray()
                return Item(range: start..<index, kind: .array)
            case 0x2F: // /
                index += 1
                while index < bytes.count, !Self.whitespace.contains(bytes[index]),
                      !Self.delimiters.contains(bytes[index]) { index += 1 }
                return Item(range: start..<index, kind: .name)
            case 0x5D, 0x3E, 0x7B, 0x7D: // stray closers
                index += 1
                return Item(range: start..<index, kind: .name)
            default:
                while index < bytes.count, !Self.whitespace.contains(bytes[index]),
                      !Self.delimiters.contains(bytes[index]) { index += 1 }
                if index == start { index += 1 }
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                if let value = Double(text) { return Item(range: start..<index, kind: .number(CGFloat(value))) }
                if text == "BI" {
                    skipInlineImage()
                    return Item(range: start..<index, kind: .inlineImage)
                }
                return Item(range: start..<index, kind: .operatorName(text))
            }
        }

        private mutating func skipBlanks() {
            while index < bytes.count {
                if Self.whitespace.contains(bytes[index]) {
                    index += 1
                } else if bytes[index] == 0x25 { // % comment
                    while index < bytes.count, bytes[index] != 0x0A, bytes[index] != 0x0D { index += 1 }
                } else {
                    return
                }
            }
        }

        private mutating func skipLiteralString() {
            index += 1
            var depth = 1
            while index < bytes.count, depth > 0 {
                switch bytes[index] {
                case 0x5C: index += 1 // backslash escapes whatever follows
                case 0x28: depth += 1
                case 0x29: depth -= 1
                default: break
                }
                index += 1
            }
        }

        private mutating func skipArray() {
            index += 1
            var depth = 1
            while index < bytes.count, depth > 0 {
                switch bytes[index] {
                case 0x28: skipLiteralString(); continue
                case 0x5B: depth += 1
                case 0x5D: depth -= 1
                default: break
                }
                index += 1
            }
        }

        private mutating func skipNested(open: (UInt8, UInt8), close: (UInt8, UInt8)) {
            index += 2
            var depth = 1
            while index + 1 < bytes.count, depth > 0 {
                if bytes[index] == 0x28 { skipLiteralString(); continue }
                if bytes[index] == open.0, bytes[index + 1] == open.1 { depth += 1; index += 2; continue }
                if bytes[index] == close.0, bytes[index + 1] == close.1 { depth -= 1; index += 2; continue }
                index += 1
            }
        }

        /// An inline image carries raw bytes between ID and EI, which must not be read as
        /// tokens. The end is an EI standing on its own.
        private mutating func skipInlineImage() {
            while index + 1 < bytes.count {
                if bytes[index] == 0x49, bytes[index + 1] == 0x44 { // ID
                    index += 2
                    break
                }
                index += 1
            }
            index += 1 // the single space after ID
            while index + 1 < bytes.count {
                if bytes[index] == 0x45, bytes[index + 1] == 0x49, // EI
                   index > 0, Self.whitespace.contains(bytes[index - 1]),
                   index + 2 >= bytes.count || Self.whitespace.contains(bytes[index + 2]) {
                    index += 2
                    return
                }
                index += 1
            }
            index = bytes.count
        }
    }
}

// MARK: - Finding the stream in the file, and putting the edited one back

extension ContentStreamEditor {
    /// The object number of the single page's content stream.
    ///
    /// Only ever asked of a file this app has just written with Core Graphics, whose page
    /// dictionary is plain text; anything else returns nil and is left alone.
    static func contentsObject(in pdf: Data) -> Int? {
        let bytes = [UInt8](pdf)
        guard let page = find(Array("/Type /Page".utf8), in: bytes) else { return nil }
        guard let contents = find(Array("/Contents".utf8), in: bytes, from: page) else { return nil }
        var index = contents + 9
        while index < bytes.count, bytes[index] == 0x20 { index += 1 }
        var digits = ""
        while index < bytes.count, bytes[index] >= 0x30, bytes[index] <= 0x39 {
            digits.append(Character(UnicodeScalar(bytes[index])))
            index += 1
        }
        return Int(digits)
    }

    /// The page's content stream, decoded. Core Graphics compresses what it writes, and
    /// PDFKit is the thing that already knows how to undo that.
    static func decodedContentStream(of pdf: Data) -> Data? {
        guard let document = CGPDFDocument(CGDataProvider(data: pdf as CFData)!),
              let page = document.page(at: 1),
              let dictionary = page.dictionary else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(dictionary, "Contents", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        // Only a stream PDFKit handed back whole; a JPEG-shaped one is not page content.
        guard format == .raw else { return nil }
        return data as Data
    }

    /// The file with one object replaced, written as an incremental update.
    ///
    /// Appending rather than rebuilding keeps every other object — the fonts, the colour
    /// profiles, the page tree — exactly as Core Graphics wrote them, byte for byte.
    static func appendingUpdate(object: Int, stream: Data, to pdf: Data) -> Data? {
        let bytes = [UInt8](pdf)
        guard let trailerStart = findLast(Array("trailer".utf8), in: bytes),
              let startxrefStart = findLast(Array("startxref".utf8), in: bytes) else { return nil }
        let trailerText = String(decoding: bytes[(trailerStart + 7)..<startxrefStart], as: UTF8.self)
        guard let open = trailerText.range(of: "<<"), let close = trailerText.range(of: ">>", options: .backwards) else {
            return nil
        }
        var dictionary = String(trailerText[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictionary.contains("/Prev") else { return nil }

        let previous = String(decoding: bytes[(startxrefStart + 9)...], as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { !$0.isNumber })
            .first
            .flatMap { Int($0) }
        guard let previous else { return nil }
        dictionary += " /Prev \(previous)"

        var output = pdf
        if output.last != 0x0A { output.append(0x0A) }
        let objectOffset = output.count
        output.append(contentsOf: Array("\(object) 0 obj\n<< /Length \(stream.count) >>\nstream\n".utf8))
        output.append(stream)
        output.append(contentsOf: Array("\nendstream\nendobj\n".utf8))

        let xrefOffset = output.count
        var xref = "xref\n\(object) 1\n"
        xref += String(format: "%010d 00000 n \n", objectOffset)
        xref += "trailer\n<< \(dictionary) >>\nstartxref\n\(xrefOffset)\n%%EOF\n"
        output.append(contentsOf: Array(xref.utf8))
        return output
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int = 0) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for index in start...(haystack.count - needle.count)
        where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }

    private static func findLast(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        for index in stride(from: haystack.count - needle.count, through: 0, by: -1)
        where Array(haystack[index..<(index + needle.count)]) == needle {
            return index
        }
        return nil
    }
}
