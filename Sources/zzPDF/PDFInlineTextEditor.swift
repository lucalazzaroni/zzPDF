import AppKit
import PDFKit

/// An editor that sits exactly on top of a free-text annotation and mirrors its
/// font, colors, and alignment, so replaced page text is edited where it lives.
final class PDFInlineTextEditor: NSView, NSTextViewDelegate {
    private(set) weak var annotation: PDFAnnotation?
    private let textView = NSTextView(frame: .zero)
    private var pdfFont: NSFont = .systemFont(ofSize: 12)
    private var singleLine = false
    private var didFinish = false
    /// Typing history stays with the editor instead of going to the window, where the
    /// document's own undo would end up replaying it.
    private let typingUndoManager = UndoManager()
    private var restoresAnnotationVisibility = false

    /// The point size the editor is actually drawing with, for tests and diagnostics.
    var displayedFontSize: CGFloat { textView.font?.pointSize ?? 0 }

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

    private(set) var frameBounds: CGRect = .zero

    func prepare(for request: InlineEditorRequest) {
        let annotation = request.annotation
        self.annotation = annotation
        self.singleLine = request.singleLine
        self.frameBounds = request.frameBounds
        pdfFont = annotation.font ?? .systemFont(ofSize: 12)
        textView.string = request.seedText
        textView.alignment = annotation.alignment
        textView.textColor = annotation.fontColor ?? .black
        textView.insertionPointColor = annotation.fontColor ?? .black
        restoresAnnotationVisibility = annotation.shouldDisplay
        annotation.shouldDisplay = false
        applyAppearance()
    }

    func updateLayout(frame: NSRect) {
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
    /// Handles Cmd-Z while the editor is open. Returns true whenever an editor is on
    /// screen, so the shortcut never falls through to the document's history mid-edit.
    func undoTyping() -> Bool {
        if typingUndoManager.canUndo { typingUndoManager.undo() }
        return true
    }

    func redoTyping() -> Bool {
        if typingUndoManager.canRedo { typingUndoManager.redo() }
        return true
    }

    func undoManager(for view: NSTextView) -> UndoManager? {
        typingUndoManager
    }

    func detach() {
        guard !didFinish else { return }
        didFinish = true
        if let annotation, restoresAnnotationVisibility { annotation.shouldDisplay = true }
        removeFromSuperview()
    }

    private func applyAppearance() {
        let background = annotation?.color ?? .clear
        layer?.backgroundColor = background.alphaComponent > 0.01 ? background.cgColor : NSColor.textBackgroundColor.cgColor
        // The page overlay this editor lives in is itself in page coordinates: PDFKit
        // scales it with the zoom. So the font goes in at its PDF point size, and scaling
        // it here as well would show the text at the zoom factor squared.
        textView.font = pdfFont
        let inset = NSSize(width: FreeTextLayout.horizontalInset, height: FreeTextLayout.topPadding)
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

/// What the in-place editor needs to open: the annotation it writes back to, the text it
/// starts with, and the box it covers. For a replaced block those differ — the editor spans
/// every line while writing back through the first one.
struct InlineEditorRequest {
    let annotation: PDFAnnotation
    let page: PDFPage
    let singleLine: Bool
    let seedText: String
    let frameBounds: CGRect
}
