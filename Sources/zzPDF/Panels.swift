import AppKit
import PDFKit
import SwiftUI

struct PageSidebar: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAGES")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(workspace.pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<workspace.pageCount, id: \.self) { index in
                            PageThumbnail(index: index, selected: index == workspace.currentPageIndex)
                                .id(index)
                                .onTapGesture { workspace.selectPage(index) }
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
                Button { workspace.duplicateCurrentPage() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplicate")
                Spacer()
                Button(role: .destructive) { workspace.deleteCurrentPage() } label: { Image(systemName: "trash") }
                    .help("Delete")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 13)
            .frame(height: 38)
        }
        .frame(minWidth: 145, idealWidth: 175, maxWidth: 215)
        .background(Color(nsColor: .controlBackgroundColor))
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
            if ![.select, .fillForms, .editText, .highlight, .redact].contains(workspace.activeTool) {
                HStack {
                    Text("Color").font(.callout)
                    Spacer()
                    ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: true)
                        .labelsHidden()
                }
            }
            if [.draw, .signature].contains(workspace.activeTool) ||
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
                InspectorIconButton(icon: "rotate.left", help: "Rotate Left") { workspace.rotateCurrentPage(by: -90) }
                InspectorIconButton(icon: "rotate.right", help: "Rotate Right") { workspace.rotateCurrentPage(by: 90) }
                InspectorIconButton(icon: "plus.square.on.square", help: "Duplicate") { workspace.duplicateCurrentPage() }
                InspectorIconButton(icon: "scissors", help: "Extract") { workspace.extractCurrentPage() }
            }
            HStack {
                Button("Trim Margins") { workspace.changePageBox(.cropBox, inset: 8) }
                Button("Reset") { workspace.resetCurrentCrop() }
            }
            .controlSize(.small)
        }
    }

    private var documentControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("DOCUMENT")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Button { workspace.mergePDF() } label: { Label("Merge PDF…", systemImage: "square.stack.3d.up") }
            Button { workspace.importImages() } label: { Label("Add Images…", systemImage: "photo.on.rectangle.angled") }
            Button { workspace.recognizeCurrentPage() } label: { Label("Recognize Text (OCR)", systemImage: "text.viewfinder") }
            Button { workspace.exportFlattened() } label: { Label("Export Flattened…", systemImage: "doc.badge.gearshape") }
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
