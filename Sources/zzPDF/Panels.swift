import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarMode: String, CaseIterable, Identifiable {
    case pages, outline, annotations, search

    var id: String { rawValue }
    var label: String {
        switch self {
        case .pages: "Pages"
        case .outline: "Contents"
        case .annotations: "Notes"
        case .search: "Search"
        }
    }
    var symbol: String {
        switch self {
        case .pages: "doc.on.doc"
        case .outline: "list.bullet.indent"
        case .annotations: "bubble.left.and.text.bubble.right"
        case .search: "magnifyingglass"
        }
    }
}

struct PageSidebar: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @State private var mode: SidebarMode

    init(mode: SidebarMode = .pages) {
        _mode = State(initialValue: mode)
    }

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $mode) {
                ForEach(SidebarMode.allCases) { option in
                    Image(systemName: option.symbol).help(option.label).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 6)

            switch mode {
            case .pages: pageList
            case .outline: outlineList
            case .annotations: annotationList
            case .search: searchList
            }
        }
        .onReceive(workspace.$searchFocusRequest.dropFirst()) { _ in mode = .search }
        .frame(minWidth: 155, idealWidth: 195, maxWidth: 260)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var pageList: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<workspace.pageCount, id: \.self) { index in
                            PageThumbnail(index: index, selected: workspace.isPageSelected(index))
                                .id(index)
                                .onTapGesture { workspace.selectPage(index) }
                                .contextMenu { pageMenu(for: index) }
                                .draggable(PageDragItem(index: index)) {
                                    PageThumbnail(index: index, selected: false)
                                        .frame(width: 90)
                                }
                                .dropDestination(for: PageDragItem.self) { items, _ in
                                    guard let item = items.first else { return false }
                                    workspace.reorderPage(from: item.index, to: index)
                                    return true
                                }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: workspace.currentPageIndex) { _, value in
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Button { workspace.moveCurrentPage(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Move Up")
                    .disabled(workspace.currentPageIndex == 0)
                Button { workspace.moveCurrentPage(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Move Down")
                    .disabled(workspace.currentPageIndex >= workspace.pageCount - 1)
                Button { workspace.duplicateSelectedPages() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                Button { workspace.extractSelectedPages() } label: { Image(systemName: "scissors") }
                    .help("Extract Selected Pages…")
                Spacer()
                Button(role: .destructive) { workspace.deleteSelectedPages() } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 13)
            .frame(height: 38)
            if workspace.selectedPageIndexes.count > 1 {
                Text("\(workspace.selectedPageIndexes.count) pages selected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
            }
        }
    }

    @ViewBuilder
    private func pageMenu(for index: Int) -> some View {
        Button("Select") { workspace.selectPage(index) }
        Button(workspace.isPageSelected(index) ? "Remove from Selection" : "Add to Selection") {
            workspace.togglePageSelection(index)
        }
        Button("Select Through Here") { workspace.extendPageSelection(to: index) }
        Divider()
        Button("Rotate Left") { workspace.rotateSelectedPages(by: -90) }
        Button("Rotate Right") { workspace.rotateSelectedPages(by: 90) }
        Button("Duplicate") { workspace.duplicateSelectedPages() }
        Button("Extract…") { workspace.extractSelectedPages() }
        Divider()
        Button("Delete", role: .destructive) { workspace.deleteSelectedPages() }
    }

    @ViewBuilder
    private var outlineList: some View {
        if let nodes = OutlineNode.tree(of: workspace.outlineRoot), !nodes.isEmpty {
            List(nodes, children: \.children) { node in
                Button {
                    workspace.goToOutline(node.outline)
                } label: {
                    Text(node.label)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.sidebar)
        } else {
            sidebarPlaceholder("This PDF has no table of contents.")
        }
    }

    @ViewBuilder
    private var annotationList: some View {
        let entries = workspace.annotationEntries()
        if entries.isEmpty {
            sidebarPlaceholder("Nothing annotated yet.")
        } else {
            List(entries) { entry in
                Button {
                    workspace.reveal(entry.annotation)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: entry.symbol)
                            .foregroundStyle(.secondary)
                            .frame(width: 15)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.summary)
                                .lineLimit(2)
                            Text("\(entry.kind) · page \(entry.pageIndex + 1)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let attribution = entry.attribution {
                                Text(attribution)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Show") { workspace.reveal(entry.annotation) }
                    if entry.isEditable {
                        Button("Edit…") { workspace.edit(entry.annotation) }
                    }
                    Button("Delete", role: .destructive) { workspace.remove(entry.annotation) }
                }
            }
            .listStyle(.sidebar)
        }
    }

    @ViewBuilder
    private var searchList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Match case", isOn: $workspace.searchMatchesCase)
                Toggle("Whole words", isOn: $workspace.searchWholeWords)
            }
            .toggleStyle(.checkbox)
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.bottom, 6)
            Divider()

            if workspace.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                sidebarPlaceholder("Type in the search field to look through the document.")
            } else if workspace.searchResults.isEmpty {
                sidebarPlaceholder(workspace.isSearching ? "Searching…" : "No results.")
            } else {
                List(Array(workspace.searchResults.enumerated()), id: \.offset) { index, result in
                    Button {
                        workspace.showSearchResult(result)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(workspace.searchSnippet(for: result))
                                .lineLimit(3)
                                .font(.callout)
                            Text("Page \(workspace.pageNumber(for: result))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(index == workspace.searchIndex ? Color.accentColor.opacity(0.16) : Color.clear)
                }
                .listStyle(.sidebar)
                if workspace.isSearching {
                    Text("Searching… \(workspace.searchResults.count) so far")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 6)
                }
            }
        }
    }

    private func sidebarPlaceholder(_ message: String) -> some View {
        VStack {
            Spacer()
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct OutlineNode: Identifiable {
    let id = UUID()
    let label: String
    let outline: PDFOutline
    let children: [OutlineNode]?

    static func tree(of root: PDFOutline?) -> [OutlineNode]? {
        guard let root else { return nil }
        return (0..<root.numberOfChildren).compactMap { index in
            guard let child = root.child(at: index) else { return nil }
            let grandchildren = tree(of: child)
            return OutlineNode(
                label: child.label ?? "Untitled",
                outline: child,
                children: (grandchildren?.isEmpty ?? true) ? nil : grandchildren
            )
        }
    }
}

struct PageThumbnail: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    let index: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let page = workspace.pdfDocument?.page(at: index) {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 126, height: 164), for: .cropBox))
                        .resizable()
                        .scaledToFit()
                        .background(.white)
                } else {
                    Rectangle().fill(.white)
                }
            }
            .frame(maxWidth: 126, minHeight: 90, maxHeight: 164)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .padding(4)
        .contentShape(Rectangle())
    }
}

struct InspectorPanel: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @EnvironmentObject private var preferences: AppPreferences

    static let fontFamilies = NSFontManager.shared.availableFontFamilies
    static let stampFonts = [
        "Helvetica", "Helvetica-Bold", "Helvetica-Oblique",
        "Times-Roman", "Times-Bold", "Times-Italic",
        "Courier", "Courier-Bold"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorHeader
                Divider()
                activeToolControls
                if workspace.activeTool == .select && (workspace.hasTextSelection || workspace.selectedAnnotation != nil) {
                    Divider()
                    markupControls
                }
                Divider()
                pageControls
                Divider()
                documentControls
            }
            .padding(16)
        }
        .frame(minWidth: 245, idealWidth: 270, maxWidth: 310)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workspace.displayName)
                .font(.headline)
                .lineLimit(1)
            Text("\(workspace.pageCount) pages")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeToolControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(workspace.activeTool.label, systemImage: workspace.activeTool.symbol)
                .font(.subheadline.weight(.semibold))
            if workspace.activeTool == .text {
                TextField("Text to insert", text: $workspace.textToInsert, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                if workspace.selectedAnnotationIsFreeText {
                    selectedTextSizeControls
                } else {
                    newTextSizeControls
                }
            }
            if workspace.activeTool == .editText, workspace.selectedAnnotationIsFreeText {
                replacedTextControls
            }
            if ![.select, .fillForms, .editText, .redact].contains(workspace.activeTool) {
                HStack {
                    Text("Color").font(.callout)
                    Spacer()
                    ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: true)
                        .labelsHidden()
                }
            }
            if workspace.activeTool == .highlight {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Highlight Strength").font(.callout)
                        Spacer()
                        Text("\(Int(preferences.highlightOpacity * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $preferences.highlightOpacity, in: 0.1...1)
                }
            }
            if [.draw, .signature, .line, .arrow, .polygon].contains(workspace.activeTool) ||
                ([.rectangle, .oval].contains(workspace.activeTool) && !workspace.selectedAnnotationIsShape) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Stroke Width").font(.callout)
                        Spacer()
                        Text(String(format: "%.1f pt", workspace.lineWidth))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $workspace.lineWidth, in: 0.5...12)
                }
            }
            if [.rectangle, .oval].contains(workspace.activeTool) && !workspace.selectedAnnotationIsShape {
                Toggle("Fill", isOn: $workspace.shapeHasFill)
                if workspace.shapeHasFill {
                    HStack {
                        Text("Fill Color").font(.callout)
                        Spacer()
                        ColorPicker("", selection: $workspace.shapeFillColor, supportsOpacity: true)
                            .labelsHidden()
                    }
                }
            }
            if [.rectangle, .oval].contains(workspace.activeTool) && workspace.selectedAnnotationIsShape {
                selectedShapeControls
            }
            if workspace.activeTool == .signature {
                HStack {
                    Button(workspace.savedSignature.isEmpty ? "Draw Signature…" : "Edit Drawing…") {
                        workspace.showSignaturePad = true
                    }
                    Button("Use Image…") { workspace.importSignatureImage() }
                }
                if workspace.hasSignature {
                    Button("Forget Signature") { workspace.forgetSignature() }
                        .controlSize(.small)
                }
            }
            Text(toolHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolHint: String {
        switch workspace.activeTool {
        case .select: "Select text and annotations. Double-click a note or added text to edit it."
        case .fillForms: "Fill text fields, select choices, and toggle checkboxes without annotation handles in the way."
        case .editText: "Click a line of text to rewrite it in place, or drag across several lines to replace a whole block. The original font, size, color, and paper color are reused."
        case .highlight: "Drag across text to highlight it immediately. The tool stays active for the next passage."
        case .underline: "Drag across text to underline it immediately. The tool stays active for the next passage."
        case .strikeOut: "Drag across text to strike it out immediately. The tool stays active for the next passage."
        case .note: "Click the page, then type the note immediately."
        case .text: "Click the page to insert the text."
        case .draw: "Drag on the page to draw freehand."
        case .line: "Drag to draw a straight line."
        case .arrow: "Drag from the tail to the head of the arrow."
        case .polygon: "Click each corner. Return closes the shape, double-click finishes it, Escape discards it."
        case .rectangle, .oval: "Drag to draw the shape. A live preview shows its size."
        case .redact: "Drag over sensitive content, then export a flattened copy to make the redaction permanent."
        case .signature: "Move over the page to preview the signature, then click to place it."
        }
    }

    private var markupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(workspace.selectedAnnotation == nil ? "SELECTED TEXT" : "SELECTED ANNOTATION")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if workspace.selectedAnnotation != nil {
                HStack {
                    Label("Annotation selected", systemImage: "selection.pin.in.out")
                        .font(.callout)
                    Spacer()
                }
                if workspace.selectedAnnotation?.isSubtype(.text) == true {
                    Button("Edit Note…") { workspace.beginEditingSelectedNote() }
                        .controlSize(.small)
                } else if workspace.selectedAnnotation?.isSubtype(.freeText) == true,
                          let annotation = workspace.selectedAnnotation {
                    Button("Edit Text…") {
                        if workspace.selectedAnnotationIsTextReplacement {
                            workspace.beginInlineTextEditing(annotation)
                        } else {
                            workspace.beginEditingFreeText(annotation)
                        }
                    }
                    .controlSize(.small)
                    selectedTextSizeControls
                    replacedTextControls
                }
                if workspace.selectedAnnotationIsShape {
                    selectedShapeControls
                }
            }
            HStack(spacing: 8) {
                if workspace.hasTextSelection {
                    InspectorIconButton(icon: "highlighter", help: "Highlight") { workspace.addMarkup(.highlight) }
                    InspectorIconButton(icon: "underline", help: "Underline") { workspace.addMarkup(.underline) }
                    InspectorIconButton(icon: "strikethrough", help: "Strike Through") { workspace.addMarkup(.strikeOut) }
                }
                if workspace.selectedAnnotation != nil {
                    InspectorIconButton(icon: "trash", help: "Remove Annotation") { workspace.removeSelectedAnnotation() }
                }
            }
        }
    }

    private var signatureSummary: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(
                workspace.digitalSignatures.count == 1
                    ? "Digitally signed"
                    : "\(workspace.digitalSignatures.count) digital signatures",
                systemImage: "seal"
            )
            .font(.callout.weight(.medium))
            ForEach(workspace.digitalSignatures) { signature in
                VStack(alignment: .leading, spacing: 1) {
                    if let signer = signature.signer {
                        Text(signer).font(.caption)
                    }
                    Text(signature.schemeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let date = signature.signedAt {
                        Text(date.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.leading, 4)
            }
            Text("zzPDF does not check signatures. Use a validator to confirm one.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 2)
    }

    private var replacedTextControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            if workspace.selectedAnnotationIsFreeText {
                if workspace.activeTool == .editText {
                    Button("Edit Text…") {
                        if let annotation = workspace.selectedAnnotation {
                            workspace.beginInlineTextEditing(annotation)
                        }
                    }
                    .controlSize(.small)
                    selectedTextSizeControls
                }
                HStack {
                    Picker("", selection: Binding(
                        get: { workspace.selectedTextFontFamily },
                        set: { workspace.setSelectedTextFontFamily($0) }
                    )) {
                        ForEach(InspectorPanel.fontFamilies, id: \.self) { family in
                            Text(family).tag(family)
                        }
                    }
                    .labelsHidden()
                    Button {
                        workspace.toggleSelectedTextTrait(bold: true)
                    } label: {
                        Image(systemName: "bold")
                            .frame(width: 22, height: 20)
                            .background(
                                workspace.selectedTextIsBold ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Bold")
                    Button {
                        workspace.toggleSelectedTextTrait(bold: false)
                    } label: {
                        Image(systemName: "italic")
                            .frame(width: 22, height: 20)
                            .background(
                                workspace.selectedTextIsItalic ? Color.accentColor.opacity(0.25) : Color.clear,
                                in: RoundedRectangle(cornerRadius: 5)
                            )
                    }
                    .buttonStyle(.plain)
                    .help("Italic")
                }
                HStack {
                    Text("Text Color").font(.callout)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { workspace.selectedTextColor },
                            set: { workspace.setSelectedTextColor($0) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                HStack {
                    Text("Background").font(.callout)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { workspace.selectedTextBackground },
                            set: { workspace.setSelectedTextBackground($0) }
                        ),
                        supportsOpacity: false
                    )
                    .labelsHidden()
                }
                Picker(
                    "Alignment",
                    selection: Binding(
                        get: { workspace.selectedTextAlignment },
                        set: { workspace.setSelectedTextAlignment($0) }
                    )
                ) {
                    Image(systemName: "text.alignleft").tag(NSTextAlignment.left)
                    Image(systemName: "text.aligncenter").tag(NSTextAlignment.center)
                    Image(systemName: "text.alignright").tag(NSTextAlignment.right)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }
    }

    private var newTextSizeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            textSizeHeader(workspace.textFontSize)
            Slider(value: $workspace.textFontSize, in: 8...72, step: 1)
        }
    }

    private var selectedTextSizeControls: some View {
        VStack(alignment: .leading, spacing: 4) {
            textSizeHeader(workspace.selectedTextFontSize)
            Slider(
                value: Binding(
                    get: { workspace.selectedTextFontSize },
                    set: { workspace.previewSelectedTextFontSize($0) }
                ),
                in: 8...72,
                step: 1,
                onEditingChanged: { editing in
                    if editing { workspace.beginSelectedTextSizeChange() }
                    else { workspace.endSelectedTextSizeChange() }
                }
            )
        }
    }

    private func textSizeHeader(_ size: Double) -> some View {
        HStack {
            Text("Text Size").font(.callout)
            Spacer()
            Text("\(Int(size.rounded())) pt")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var selectedShapeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Stroke Width").font(.callout)
                Spacer()
                Text(String(format: "%.1f pt", workspace.selectedShapeStrokeWidth))
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { workspace.selectedShapeStrokeWidth },
                    set: { workspace.previewSelectedShapeStrokeWidth($0) }
                ),
                in: 0.5...12,
                onEditingChanged: { editing in
                    if editing { workspace.beginSelectedShapeStrokeChange() }
                    else { workspace.endSelectedShapeStrokeChange() }
                }
            )
            Toggle(
                "Fill",
                isOn: Binding(
                    get: { workspace.selectedShapeHasFill },
                    set: { workspace.setSelectedShapeFillEnabled($0) }
                )
            )
            if workspace.selectedShapeHasFill {
                HStack {
                    Text("Fill Color").font(.callout)
                    Spacer()
                    ColorPicker(
                        "",
                        selection: Binding(
                            get: { workspace.selectedShapeFillColor },
                            set: { workspace.setSelectedShapeFillColor($0) }
                        ),
                        supportsOpacity: true
                    )
                    .labelsHidden()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var pageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAGE")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Picker("Layout", selection: $workspace.pageLayout) {
                ForEach(PageLayoutMode.allCases) { layout in
                    Label(layout.label, systemImage: layout.symbol).tag(layout)
                }
            }
            .onChange(of: workspace.pageLayout) { _, layout in workspace.setPageLayout(layout) }
            HStack(spacing: 8) {
                InspectorIconButton(icon: "rotate.left", help: "Rotate Left") { workspace.rotateSelectedPages(by: -90) }
                InspectorIconButton(icon: "rotate.right", help: "Rotate Right") { workspace.rotateSelectedPages(by: 90) }
                InspectorIconButton(icon: "plus.square.on.square", help: "Duplicate") { workspace.duplicateSelectedPages() }
                InspectorIconButton(icon: "scissors", help: "Extract") { workspace.extractSelectedPages() }
            }
            HStack {
                Button("Trim Margins") { workspace.changePageBox(.cropBox, inset: 8) }
                Button("Reset") { workspace.resetCurrentCrop() }
            }
            .controlSize(.small)
            Picker("", selection: Binding(
                get: { preferences.readingMode },
                set: { workspace.setReadingMode($0) }
            )) {
                ForEach(ReadingMode.allCases) { mode in
                    Image(systemName: mode.symbol).help(mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
    }

    private var documentControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("DOCUMENT")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if !workspace.digitalSignatures.isEmpty {
                signatureSummary
            }
            Button { workspace.mergePDF() } label: { Label("Merge PDF…", systemImage: "square.stack.3d.up") }
            Button { workspace.importImages() } label: { Label("Add Images…", systemImage: "photo.on.rectangle.angled") }
            Button { workspace.recognizeCurrentPage() } label: { Label("Read Text on This Page…", systemImage: "text.viewfinder") }
            Button { workspace.makeDocumentSearchable() } label: {
                Label("Make Scanned Pages Searchable", systemImage: "doc.text.magnifyingglass")
            }
            .disabled(workspace.isRecognizingText)
            Button { workspace.exportFlattened() } label: { Label("Export Flattened…", systemImage: "doc.badge.gearshape") }
            Button { workspace.exportPagesAsImages() } label: { Label("Export Pages as Images…", systemImage: "photo") }
            Button { workspace.exportSmallerCopy() } label: { Label("Export Smaller Copy…", systemImage: "arrow.down.circle") }
            Button { workspace.beginPageStamp(PageStamper.Options()) } label: {
                Label("Page Numbers & Headers…", systemImage: "number")
            }
            Button { workspace.beginPageStamp(.watermark) } label: {
                Label("Watermark…", systemImage: "drop")
            }
            Button { workspace.beginSplit() } label: { Label("Split Document…", systemImage: "square.split.1x2") }
            Button { workspace.compareWithAnotherPDF() } label: {
                Label("Compare with Another PDF…", systemImage: "arrow.left.arrow.right")
            }
            if workspace.hasFormFields {
                Button { workspace.exportFormData() } label: { Label("Export Form Data…", systemImage: "tray.and.arrow.up") }
                Button { workspace.importFormData() } label: { Label("Fill from Form Data…", systemImage: "tray.and.arrow.down") }
            }
            Button { workspace.showPasswordExport = true } label: { Label("Password Protect…", systemImage: "lock") }
            if workspace.isPasswordProtected {
                Button { workspace.removePasswordProtection() } label: {
                    Label("Export Without Password…", systemImage: "lock.open")
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct InspectorIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 31, height: 28)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SignatureSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Binding var strokes: [[CGPoint]]
    @State private var workingStrokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Signature").font(.title2.bold())
                Text("Draw in the box with your mouse or trackpad, or import an image file.").foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Canvas { context, size in
                    for stroke in workingStrokes + (currentStroke.isEmpty ? [] : [currentStroke]) {
                        guard let first = stroke.first else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(
                                x: min(max(value.location.x / geometry.size.width, 0), 1),
                                y: min(max(value.location.y / geometry.size.height, 0), 1)
                            )
                            currentStroke.append(point)
                        }
                        .onEnded { _ in
                            if currentStroke.count > 1 { workingStrokes.append(currentStroke) }
                            currentStroke = []
                        }
                )
            }
            .frame(height: 220)
            HStack {
                Button("Clear") { workingStrokes = []; currentStroke = [] }
                Button("Use Image File…") {
                    workspace.importSignatureImage()
                    dismiss()
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Use Drawing") {
                    strokes = workingStrokes
                    workspace.useDrawnSignature(workingStrokes)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(workingStrokes.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 580, height: 360)
        .onAppear { workingStrokes = strokes }
    }
}

struct PasswordExportSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var ownerPassword = ""
    @State private var userPassword = ""
    @State private var flatten = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Protect a Copy").font(.title2.bold())
            Text("An owner password is required. The password needed to open the file is optional.")
                .foregroundStyle(.secondary)
            Form {
                SecureField("Owner Password", text: $ownerPassword)
                SecureField("Open Password", text: $userPassword)
                Toggle("Flatten annotations and signature", isOn: $flatten)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Export…") {
                    workspace.exportProtected(ownerPassword: ownerPassword, userPassword: userPassword, flatten: flatten)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ownerPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 300)
    }
}

struct OCRResultSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Recognized Text").font(.title2.bold())
            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("You can correct the text before copying it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 650, height: 500)
    }
}

struct NoteEditorSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Note").font(.title2.bold())
            TextEditor(text: $workspace.annotationDraftText)
                .font(.body)
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("The note remains attached to its marker on the page.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    workspace.cancelNoteEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Note") {
                    workspace.commitSelectedNote()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 320)
        .interactiveDismissDisabled()
    }
}

struct FreeTextEditorSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit Text").font(.title2.bold())
            TextEditor(text: $workspace.freeTextDraftText)
                .font(.system(size: workspace.freeTextDraftFontSize))
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                .focused($editorFocused)
            HStack {
                Text("Text Size")
                Slider(value: $workspace.freeTextDraftFontSize, in: 8...72, step: 1)
                Text("\(Int(workspace.freeTextDraftFontSize.rounded())) pt")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 42, alignment: .trailing)
            }
            HStack {
                Text("This text will remain directly on the PDF page.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") {
                    workspace.cancelFreeTextEditing()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Save Text") {
                    workspace.commitFreeTextEditing()
                    dismiss()
                }
                .keyboardShortcut(.return, modifiers: [.command])
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520, height: 320)
        .interactiveDismissDisabled()
        .onAppear { editorFocused = true }
    }
}

/// Carries a page index while a thumbnail is dragged to a new position.
struct PageDragItem: Codable, Transferable {
    let index: Int

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .zzPDFPageReference)
    }
}

extension UTType {
    static let zzPDFPageReference = UTType(exportedAs: "it.lucalazzaroni.zzpdf.page-reference")
}

struct PageStampSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var preview: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.stampOptions.placement == .center ? "Watermark" : "Header, Footer or Page Number")
                    .font(.title2.bold())
                Text("The text becomes part of the page, so it survives every export and stays searchable.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .top, spacing: 18) {
                Form {
                    TextField("Text", text: $workspace.stampOptions.text, axis: .vertical)
                        .lineLimit(1...3)
                    Text(PageStamper.tokenHelp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Position", selection: $workspace.stampOptions.placement) {
                        ForEach(PageStamper.Placement.allCases) { placement in
                            Text(placement.label).tag(placement)
                        }
                    }
                    Picker("Font", selection: $workspace.stampOptions.fontName) {
                        ForEach(InspectorPanel.stampFonts, id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $workspace.stampOptions.fontSize, in: 6...144)
                            Text("\(Int(workspace.stampOptions.fontSize)) pt").monospacedDigit().frame(width: 48)
                        }
                    }
                    LabeledContent("Colour") {
                        ColorPicker("", selection: Binding(
                            get: { Color(nsColor: workspace.stampOptions.color) },
                            set: { workspace.stampOptions.color = NSColor($0) }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                    LabeledContent("Opacity") {
                        HStack {
                            Slider(value: $workspace.stampOptions.opacity, in: 0.05...1)
                            Text("\(Int(workspace.stampOptions.opacity * 100))%").monospacedDigit().frame(width: 48)
                        }
                    }
                    LabeledContent("Rotation") {
                        HStack {
                            Slider(value: $workspace.stampOptions.rotation, in: -90...90, step: 1)
                            Text("\(Int(workspace.stampOptions.rotation))°").monospacedDigit().frame(width: 48)
                        }
                    }
                    LabeledContent("Margin") {
                        HStack {
                            Slider(value: $workspace.stampOptions.margin, in: 0...120)
                            Text("\(Int(workspace.stampOptions.margin)) pt").monospacedDigit().frame(width: 48)
                        }
                    }
                    if workspace.stampOptions.text.contains("{bates}") {
                        TextField("Bates prefix", text: $workspace.stampOptions.batesPrefix)
                        Stepper("Start at \(workspace.stampOptions.batesStart)", value: $workspace.stampOptions.batesStart, in: 0...9_999_999)
                        Stepper("\(workspace.stampOptions.batesDigits) digits", value: $workspace.stampOptions.batesDigits, in: 1...12)
                    }
                    if workspace.selectedPageIndexes.count > 1 {
                        Toggle("Only the \(workspace.selectedPageIndexes.count) selected pages", isOn: $workspace.stampAppliesToSelectionOnly)
                    }
                }
                .formStyle(.grouped)
                .frame(width: 360)

                VStack(spacing: 6) {
                    Group {
                        if let preview {
                            Image(nsImage: preview)
                                .resizable()
                                .scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        }
                    }
                    .frame(width: 190, height: 250)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4).stroke(.quaternary)
                    }
                    Text("Preview of page \((workspace.stampTargetIndexes.first ?? 0) + 1)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to \(workspace.stampTargetIndexes.count) Page\(workspace.stampTargetIndexes.count == 1 ? "" : "s")") {
                    workspace.applyPageStamp()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(workspace.stampOptions.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
        .task(id: previewKey) { refreshPreview() }
    }

    /// Everything the preview depends on, so it is redrawn when any of it changes.
    private var previewKey: String {
        let options = workspace.stampOptions
        return [
            options.text, options.placement.rawValue, options.fontName,
            "\(options.fontSize)", "\(options.opacity)", "\(options.rotation)",
            "\(options.margin)", options.color.description, options.batesPrefix,
            "\(options.batesStart)", "\(options.batesDigits)", "\(workspace.stampAppliesToSelectionOnly)"
        ].joined(separator: "|")
    }

    private func refreshPreview() {
        preview = workspace.stampPreview(size: CGSize(width: 380, height: 500))
    }
}

struct SplitSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Split Document").font(.title2.bold())
                Text("The original file is left alone; each part is written as its own PDF.")
                    .foregroundStyle(.secondary)
            }
            Form {
                if workspace.outlineRoot != nil {
                    Picker("Split", selection: $workspace.splitAtContents) {
                        Text("Every few pages").tag(false)
                        Text("At each contents entry").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                }
                if !workspace.splitAtContents {
                    Stepper(
                        "Every \(workspace.splitEveryPages) page\(workspace.splitEveryPages == 1 ? "" : "s")",
                        value: $workspace.splitEveryPages,
                        in: 1...max(1, workspace.pageCount)
                    )
                }
                LabeledContent("Result") {
                    Text("\(workspace.splitPartCount) file\(workspace.splitPartCount == 1 ? "" : "s") from \(workspace.pageCount) pages")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Choose Folder…") { workspace.splitDocument() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(workspace.splitPartCount < 2)
            }
        }
        .padding(20)
        .frame(width: 430)
    }
}

struct ComparisonSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compared with \(workspace.comparedName)").font(.title2.bold())
                if workspace.isComparing {
                    Text("Comparing…").foregroundStyle(.secondary)
                } else {
                    Text(workspace.comparisonChangeCount == 0
                         ? "The two documents match."
                         : "\(workspace.comparisonChangeCount) of \(workspace.comparison.count) pages differ. Changes are marked in red.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 16) {
                List(workspace.comparison, selection: $selected) { result in
                    HStack(spacing: 7) {
                        Image(systemName: result.change.symbol)
                            .foregroundStyle(result.change.isChange ? Color.red : Color.secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Page \(result.pageNumber)")
                            Text(result.change.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .tag(result.pageNumber)
                }
                .frame(width: 210, height: 380)

                VStack(spacing: 6) {
                    Group {
                        if let page = selected ?? workspace.comparison.first(where: { $0.change.isChange })?.pageNumber,
                           let image = workspace.comparisonImage(forPageNumber: page) {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                        } else {
                            RoundedRectangle(cornerRadius: 4).fill(.quaternary)
                        }
                    }
                    .frame(width: 320, height: 380)
                    .background(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay { RoundedRectangle(cornerRadius: 4).stroke(.quaternary) }
                    Text("Red marks what the other version changed.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 620)
    }
}
