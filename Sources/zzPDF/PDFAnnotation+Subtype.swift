import PDFKit

extension PDFAnnotation {
    func isSubtype(_ subtype: PDFAnnotationSubtype) -> Bool {
        normalizedPDFSubtype(type) == normalizedPDFSubtype(subtype.rawValue)
    }
}

private func normalizedPDFSubtype(_ value: String?) -> String {
    (value ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
}
