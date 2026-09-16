import Foundation
import PDFKit

/// Reports whether a PDF carries digital signatures, and what they say about themselves.
///
/// This is detection, not verification. PDFKit exposes nothing about the signature
/// dictionary, so the file is read directly: a signed PDF holds a signature with a
/// `/ByteRange` covering the bytes it signs and a `/SubFilter` naming the scheme. Nothing
/// here checks the certificate, its chain, or whether the document has been changed since
/// it was signed — only a tool with a trust store can say that, and the app says so.
enum DigitalSignatureScanner {
    struct Signature: Identifiable {
        let id = UUID()
        let scheme: String
        let signer: String?
        let reason: String?
        let signedAt: Date?

        var schemeLabel: String {
            switch scheme {
            case let value where value.hasPrefix("ETSI.CAdES"): "PAdES (ETSI CAdES)"
            case let value where value.hasPrefix("ETSI.RFC3161"): "Document timestamp"
            case "adbe.pkcs7.detached": "PKCS#7 detached"
            case "adbe.pkcs7.sha1": "PKCS#7 SHA-1"
            case "adbe.x509.rsa_sha1": "X.509 RSA SHA-1"
            default: scheme
            }
        }
    }

    static func signatures(in document: PDFDocument) -> [Signature] {
        guard let data = document.dataRepresentation() else { return [] }
        return signatures(in: data)
    }

    static func signatures(in data: Data) -> [Signature] {
        // The signature dictionary is plain text in the file even when the rest is
        // compressed, because a signature cannot be inside an object stream.
        let text = String(decoding: data, as: UTF8.self)
        guard text.contains("/ByteRange") else { return [] }

        var found: [Signature] = []
        var searchRange = text.startIndex..<text.endIndex
        while let byteRange = text.range(of: "/ByteRange", range: searchRange) {
            let start = text.index(byteRange.lowerBound, offsetBy: -600, limitedBy: text.startIndex)
                ?? text.startIndex
            let end = text.index(byteRange.upperBound, offsetBy: 600, limitedBy: text.endIndex)
                ?? text.endIndex
            let window = String(text[start..<end])
            found.append(
                Signature(
                    scheme: value(of: "/SubFilter", in: window, isName: true) ?? "unknown",
                    signer: value(of: "/Name", in: window, isName: false),
                    reason: value(of: "/Reason", in: window, isName: false),
                    signedAt: value(of: "/M", in: window, isName: false).flatMap(parsePDFDate)
                )
            )
            searchRange = byteRange.upperBound..<text.endIndex
        }
        return found
    }

    /// Reads `/Key /Name` or `/Key (string)` out of a fragment of the file.
    private static func value(of key: String, in text: String, isName: Bool) -> String? {
        guard let keyRange = text.range(of: key) else { return nil }
        var index = keyRange.upperBound
        while index < text.endIndex, text[index] == " " { index = text.index(after: index) }
        guard index < text.endIndex else { return nil }

        if isName {
            guard text[index] == "/" else { return nil }
            index = text.index(after: index)
            var name = ""
            while index < text.endIndex, !" /<>[]()\n\r\t".contains(text[index]) {
                name.append(text[index])
                index = text.index(after: index)
            }
            return name.isEmpty ? nil : name
        }

        guard text[index] == "(" else { return nil }
        index = text.index(after: index)
        var value = ""
        var depth = 1
        while index < text.endIndex {
            let character = text[index]
            if character == "\\" {
                index = text.index(after: index)
                if index < text.endIndex {
                    value.append(text[index])
                    index = text.index(after: index)
                }
                continue
            }
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { break }
            }
            value.append(character)
            index = text.index(after: index)
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// PDF dates look like `D:20260916143000+02'00'`.
    static func parsePDFDate(_ raw: String) -> Date? {
        var digits = raw
        if digits.hasPrefix("D:") { digits.removeFirst(2) }
        digits = digits.filter { $0.isNumber }
        guard digits.count >= 8 else { return nil }
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = digits.count >= 14 ? "yyyyMMddHHmmss" : "yyyyMMdd"
        return formatter.date(from: String(digits.prefix(digits.count >= 14 ? 14 : 8)))
    }
}
