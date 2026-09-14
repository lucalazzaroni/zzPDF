import AppKit
import PDFKit

/// An editor that sits exactly on top of a free-text annotation and mirrors its
/// font, colors, and alignment, so replaced page text is edited where it lives.
final class PDFInlineTextEditor: NSView, NSTextViewDelegate {
    private(set) weak var annotation: PDFAnnotation?
    private let textView = NSTextView(frame: .zero)
    private var pdfFont: NSFont = .systemFont(ofSize: 12)
    private var scale: CGFloat = 1
    private var singleLine = false
    private var didFinish = false
    private var restoresAnnotationVisibility = false

    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?
    var onTextChange: ((String) -> NSFont?)?
    var onLayoutChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.cornerRadius = 2
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        addSubview(textView)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override var acceptsFirstResponder: Bool { true }

    func prepare(for annotation: PDFAnnotation, singleLine: Bool, scale: CGFloat) {
        self.annotation = annotation
        self.singleLine = singleLine
        self.scale = max(0.05, scale)
        pdfFont = annotation.font ?? .systemFont(ofSize: 12)
        textView.string = annotation.contents ?? ""
        textView.alignment = annotation.alignment
        textView.textColor = annotation.fontColor ?? .black
        textView.insertionPointColor = annotation.fontColor ?? .black
        restoresAnnotationVisibility = annotation.shouldDisplay
        annotation.shouldDisplay = false
        applyAppearance()
    }

    func updateLayout(frame: NSRect, scale: CGFloat) {
        self.scale = max(0.05, scale)
        self.frame = frame
        textView.frame = bounds
        textView.minSize = bounds.size
        textView.maxSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        textView.textContainer?.containerSize = NSSize(width: bounds.width, height: .greatestFiniteMagnitude)
        applyAppearance()
    }

    func focus() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: 0, length: (textView.string as NSString).length))
    }

    func commit() {
        finish(committing: true)
    }

    func cancel() {
        finish(committing: false)
    }

    /// Closes the editor without reporting back, for when the edit is being finished elsewhere.
    func detach() {
        guard !didFinish else { return }
        didFinish = true
        if let annotation, restoresAnnotationVisibility { annotation.shouldDisplay = true }
        removeFromSuperview()
    }

    private func applyAppearance() {
        let background = annotation?.color ?? .clear
        layer?.backgroundColor = background.alphaComponent > 0.01 ? background.cgColor : NSColor.textBackgroundColor.cgColor
        textView.font = TextFitting.resized(pdfFont, to: max(1, pdfFont.pointSize * scale))
        let inset = NSSize(
            width: FreeTextLayout.horizontalInset * scale,
            height: max(0, FreeTextLayout.topPadding * scale)
        )
        textView.textContainerInset = inset
        textView.textContainer?.containerSize = NSSize(
            width: max(1, bounds.width - inset.width * 2),
            height: .greatestFiniteMagnitude
        )
    }

    private func finish(committing: Bool) {
        guard !didFinish else { return }
        didFinish = true
        if let annotation, restoresAnnotationVisibility { annotation.shouldDisplay = true }
        let text = textView.string
        removeFromSuperview()
        if committing {
            onCommit?(text)
        } else {
            onCancel?()
        }
    }

    func textDidChange(_ notification: Notification) {
        if let font = onTextChange?(textView.string) { pdfFont = font }
        applyAppearance()
        onLayoutChange?()
    }

    func textDidEndEditing(_ notification: Notification) {
        finish(committing: true)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertNewline(_:)) where singleLine:
            commit()
            return true
        case #selector(NSResponder.insertTab(_:)):
            commit()
            return true
        default:
            return false
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.keyCode == 36 {
            commit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}
