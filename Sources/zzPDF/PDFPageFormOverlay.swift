import AppKit
import PDFKit

final class PDFPageFormOverlay: NSView, NSTextFieldDelegate {
    weak var owner: InteractivePDFView?
    weak var page: PDFPage?

    private var formViews: [NSView] = []
    private weak var freeTextEditor: PDFOverlayTextField?
    private(set) weak var inlineEditor: PDFInlineTextEditor?

    init(owner: InteractivePDFView, page: PDFPage) {
        self.owner = owner
        self.page = page
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    override func layout() {
        super.layout()
        updateFrames()
    }

    func refresh() {
        guard let owner else { return }
        if formViews.isEmpty { buildFormViews() }
        let showForms = owner.workspace?.activeTool == .fillForms
        for view in formViews { view.isHidden = !showForms }
        synchronizeValues()
        updateFrames()
        needsDisplay = true
    }

    func beginEditing(_ annotation: PDFAnnotation) {
        if annotation.isSubtype(.widget),
           let field = formViews.compactMap({ $0 as? PDFOverlayTextField }).first(where: { $0.annotation === annotation }) {
            focus(field)
            return
        }

        guard annotation.isSubtype(.freeText) else { return }
        freeTextEditor?.removeFromSuperview()
        let field = makeTextField(for: annotation, value: annotation.contents ?? "")
        field.isFreeTextEditor = true
        freeTextEditor = field
        addSubview(field)
        updateFrame(of: field, for: annotation)
        focus(field)
    }

    func beginInlineEditing(_ request: InlineEditorRequest) {
        guard owner != nil else { return }
        let annotation = request.annotation
        inlineEditor?.cancel()
        let editor = PDFInlineTextEditor(frame: .zero)
        editor.prepare(for: request)
        editor.onCommit = { [weak self] text in
            self?.inlineEditor = nil
            self?.owner?.workspace?.commitTextReplacement(annotation, text: text)
            self?.owner?.refreshInteractionAppearance()
        }
        editor.onCancel = { [weak self] in
            self?.inlineEditor = nil
            self?.owner?.workspace?.cancelTextReplacement(annotation)
        }
        editor.onTextChange = { [weak self] text in
            self?.owner?.workspace?.previewTextEdit(text)
        }
        editor.onLayoutChange = { [weak self] in
            self?.updateInlineEditorFrame()
        }
        inlineEditor = editor
        addSubview(editor)
        updateInlineEditorFrame()
        DispatchQueue.main.async { [weak editor] in editor?.focus() }
    }

    func commitInlineEditing() {
        inlineEditor?.commit()
        inlineEditor = nil
    }

    func cancelInlineEditing() {
        inlineEditor?.cancel()
        inlineEditor = nil
    }

    func detachInlineEditing() {
        inlineEditor?.detach()
        inlineEditor = nil
    }

    private func updateInlineEditorFrame() {
        guard let editor = inlineEditor, let owner, let page else { return }
        let bounds = editor.frameBounds.isEmpty ? (editor.annotation?.bounds ?? .zero) : editor.frameBounds
        let pdfViewRect = owner.convert(bounds, from: page).standardized
        editor.updateLayout(frame: convert(pdfViewRect, from: owner).standardized)
    }

    func cancelCurrentEditor() {
        inlineEditor?.cancel()
        inlineEditor = nil
        guard let field = freeTextEditor, let annotation = field.annotation else { return }
        owner?.workspace?.cancelEditableText(annotation)
        field.removeFromSuperview()
        freeTextEditor = nil
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? PDFOverlayTextField else { return }
        field.valueBeforeEditing = field.stringValue
    }

    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? PDFOverlayTextField,
              !field.isFreeTextEditor else { return }
        fitWidgetText(in: field)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? PDFOverlayTextField,
              let annotation = field.annotation else { return }
        let movement = notification.userInfo?["NSTextMovement"] as? Int
        if movement == NSCancelTextMovement {
            cancel(field)
            return
        }
        if annotation.isSubtype(.widget), annotation.widgetFieldType == .text {
            fitWidgetText(in: field)
            owner?.workspace?.updateFormText(
                in: annotation,
                to: field.stringValue,
                fontSize: field.fittedPDFPointSize
            )
        } else {
            owner?.workspace?.updateEditableText(in: annotation, to: field.stringValue)
        }
        if field.isFreeTextEditor {
            field.removeFromSuperview()
            freeTextEditor = nil
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard let field = control as? PDFOverlayTextField else { return false }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancel(field)
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) {
            return moveFocus(from: field, by: 1)
        }
        if commandSelector == #selector(NSResponder.insertBacktab(_:)) {
            return moveFocus(from: field, by: -1)
        }
        return false
    }

    /// Text fields in the order they appear down the page, so Tab walks the form the way
    /// the reader does rather than in whatever order the annotations were stored.
    private var orderedTextFields: [PDFOverlayTextField] {
        formViews
            .compactMap { $0 as? PDFOverlayTextField }
            .filter { $0.isEnabled && !$0.isHidden }
            .sorted { first, second in
                guard let a = first.annotation?.bounds, let b = second.annotation?.bounds else { return false }
                if abs(a.maxY - b.maxY) > 4 { return a.maxY > b.maxY }
                return a.minX < b.minX
            }
    }

    @discardableResult
    private func moveFocus(from field: PDFOverlayTextField, by offset: Int) -> Bool {
        let fields = orderedTextFields
        guard let current = fields.firstIndex(of: field) else { return false }
        let next = current + offset
        guard fields.indices.contains(next) else {
            // Past either end of this page, hand over to the page in that direction.
            return owner?.focusFirstFormField(onPageAfter: page, direction: offset) ?? false
        }
        focus(fields[next])
        return true
    }

    /// Focuses the first or last field on this page, when Tab arrives from another one.
    @discardableResult
    func focusEdgeField(last: Bool) -> Bool {
        let fields = orderedTextFields
        guard let field = last ? fields.last : fields.first else { return false }
        focus(field)
        return true
    }

    @objc private func toggleButton(_ sender: PDFOverlayButton) {
        guard let annotation = sender.annotation else { return }
        let state = PDFWidgetCellState(rawValue: sender.state == .on ? 1 : 0) ?? annotation.buttonWidgetState
        owner?.workspace?.updateButtonField(annotation, to: state)
    }

    @objc private func chooseValue(_ sender: PDFOverlayChoice) {
        guard let annotation = sender.annotation, let value = sender.titleOfSelectedItem else { return }
        owner?.workspace?.updateEditableText(in: annotation, to: value)
    }

    private func cancel(_ field: PDFOverlayTextField) {
        guard let annotation = field.annotation else { return }
        if field.isFreeTextEditor {
            owner?.workspace?.cancelEditableText(annotation)
            field.removeFromSuperview()
            freeTextEditor = nil
        } else {
            field.stringValue = field.valueBeforeEditing
            fitWidgetText(in: field)
            window?.makeFirstResponder(nil)
        }
    }

    private func focus(_ field: PDFOverlayTextField) {
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field else { return }
            self.window?.makeFirstResponder(field)
            field.selectText(nil)
        }
    }

    private func buildFormViews() {
        guard let page else { return }
        for annotation in page.annotations where annotation.isSubtype(.widget) {
            let outline = PDFFieldOutlineView(frame: .zero)
            outline.annotation = annotation
            formViews.append(outline)
            addSubview(outline)

            switch annotation.widgetFieldType {
            case .text:
                let field = makeTextField(for: annotation, value: annotation.widgetStringValue ?? "")
                field.isEnabled = !annotation.isReadOnly
                formViews.append(field)
                addSubview(field)
            case .button where annotation.widgetControlType.rawValue == 1 || annotation.widgetControlType.rawValue == 2:
                let button = PDFOverlayButton(frame: .zero)
                button.annotation = annotation
                button.title = ""
                button.setButtonType(annotation.widgetControlType.rawValue == 1 ? .radio : .switch)
                button.state = annotation.buttonWidgetState.rawValue == 1 ? .on : .off
                button.isEnabled = !annotation.isReadOnly
                button.target = self
                button.action = #selector(toggleButton(_:))
                formViews.append(button)
                addSubview(button)
            case .choice:
                let choice = PDFOverlayChoice(frame: .zero, pullsDown: false)
                choice.annotation = annotation
                choice.addItems(withTitles: annotation.choices ?? [])
                if let value = annotation.widgetStringValue { choice.selectItem(withTitle: value) }
                choice.isEnabled = !annotation.isReadOnly
                choice.target = self
                choice.action = #selector(chooseValue(_:))
                formViews.append(choice)
                addSubview(choice)
            default:
                break
            }
        }
    }

    private func makeTextField(for annotation: PDFAnnotation, value: String) -> PDFOverlayTextField {
        let field = PDFOverlayTextField(frame: .zero)
        field.annotation = annotation
        field.stringValue = value
        field.valueBeforeEditing = value
        let annotationFontSize = Double(annotation.font?.pointSize ?? 14)
        field.maximumPDFPointSize = max(14, annotationFontSize)
        field.fittedPDFPointSize = annotationFontSize
        field.font = annotation.font ?? .systemFont(ofSize: 14)
        field.textColor = annotation.fontColor
        field.backgroundColor = NSColor.textBackgroundColor.withAlphaComponent(0.96)
        field.drawsBackground = true
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = true
        field.isBezeled = true
        field.bezelStyle = .squareBezel
        field.focusRingType = .exterior
        field.delegate = self
        return field
    }

    private func updateFrames() {
        for view in formViews {
            if let field = view as? PDFOverlayTextField, let annotation = field.annotation {
                updateFrame(of: field, for: annotation)
            } else if let button = view as? PDFOverlayButton, let annotation = button.annotation {
                updateFrame(of: button, for: annotation)
            } else if let choice = view as? PDFOverlayChoice, let annotation = choice.annotation {
                updateFrame(of: choice, for: annotation)
            } else if let outline = view as? PDFFieldOutlineView, let annotation = outline.annotation {
                updateFrame(of: outline, for: annotation)
            }
        }
        if let field = freeTextEditor, let annotation = field.annotation {
            updateFrame(of: field, for: annotation)
        }
        updateInlineEditorFrame()
    }

    private func synchronizeValues() {
        for view in formViews {
            if let field = view as? PDFOverlayTextField,
               field.currentEditor() == nil,
               let annotation = field.annotation {
                field.stringValue = annotation.widgetStringValue ?? ""
            } else if let button = view as? PDFOverlayButton, let annotation = button.annotation {
                button.state = annotation.buttonWidgetState.rawValue == 1 ? .on : .off
            } else if let choice = view as? PDFOverlayChoice,
                      let annotation = choice.annotation,
                      let value = annotation.widgetStringValue {
                choice.selectItem(withTitle: value)
            }
        }
    }

    private func updateFrame(of view: NSView, for annotation: PDFAnnotation) {
        guard let owner, let page else { return }
        let pdfViewRect = owner.convert(annotation.bounds, from: page).standardized
        view.frame = convert(pdfViewRect, from: owner).standardized.insetBy(dx: 1, dy: 1)
        if let field = view as? PDFOverlayTextField,
           annotation.isSubtype(.widget),
           annotation.widgetFieldType == .text {
            fitWidgetText(in: field)
        }
    }

    private func fitWidgetText(in field: PDFOverlayTextField) {
        guard let annotation = field.annotation else { return }
        let maximumSize = field.maximumPDFPointSize
        let minimumSize = min(maximumSize, 1)
        let availableSize = CGSize(
            width: max(1, annotation.bounds.width - 8),
            height: max(1, annotation.bounds.height - 4)
        )
        let text = field.stringValue as NSString
        let baseFont = annotation.font ?? .systemFont(ofSize: field.maximumPDFPointSize)

        func font(at size: Double) -> NSFont {
            if baseFont.fontName.hasPrefix(".") {
                return .systemFont(ofSize: size)
            }
            return NSFontManager.shared.convert(baseFont, toSize: size)
        }

        guard owner?.workspace?.preferences.autoFitFormText != false else {
            field.font = font(at: maximumSize)
            field.fittedPDFPointSize = maximumSize
            return
        }

        var fittedSize = maximumSize
        if text.length > 0 {
            let measured = text.size(withAttributes: [.font: font(at: maximumSize)])
            let widthScale = availableSize.width / max(measured.width, 1)
            let heightScale = availableSize.height / max(measured.height, 1)
            fittedSize = max(minimumSize, min(maximumSize, maximumSize * min(widthScale, heightScale)))
        }
        var fittedPDFPointSize = max(1, floor(fittedSize))
        var fittedFont = font(at: fittedPDFPointSize)
        while text.length > 0, fittedPDFPointSize > 1 {
            let measured = text.size(withAttributes: [.font: fittedFont])
            guard measured.width > availableSize.width || measured.height > availableSize.height else { break }
            fittedPDFPointSize -= 1
            fittedFont = font(at: fittedPDFPointSize)
        }
        let displayAvailableSize = CGSize(
            width: max(1, field.bounds.width - 8),
            height: max(1, field.bounds.height - 6)
        )
        var displaySize = maximumSize
        if text.length > 0 {
            let measured = text.size(withAttributes: [.font: font(at: maximumSize)])
            let widthScale = displayAvailableSize.width / max(measured.width, 1)
            let heightScale = displayAvailableSize.height / max(measured.height, 1)
            displaySize = max(1, min(maximumSize, maximumSize * min(widthScale, heightScale)))
        }
        var displayFont = font(at: displaySize)
        while text.length > 0, displaySize > 1 {
            let measured = text.size(withAttributes: [.font: displayFont])
            guard measured.width > displayAvailableSize.width || measured.height > displayAvailableSize.height else { break }
            displaySize = max(1, displaySize - 0.5)
            displayFont = font(at: displaySize)
        }
        field.font = displayFont
        field.fittedPDFPointSize = fittedPDFPointSize
    }
}

final class PDFOverlayTextField: NSTextField {
    weak var annotation: PDFAnnotation?
    var valueBeforeEditing = ""
    var isFreeTextEditor = false
    var maximumPDFPointSize: Double = 14
    var fittedPDFPointSize: Double = 14
}

final class PDFOverlayButton: NSButton {
    weak var annotation: PDFAnnotation?
}

final class PDFOverlayChoice: NSPopUpButton {
    weak var annotation: PDFAnnotation?
}

final class PDFFieldOutlineView: NSView {
    weak var annotation: PDFAnnotation?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 3
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.10).cgColor
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
