import AppKit
import PDFKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @State private var dropTargeted = false

    /// Accepts PDFs and images dropped on the window: a PDF opens like any other
    /// document, images are added as pages.
    private func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, url.isFileURL else { return }
                Task { @MainActor in
                    if url.pathExtension.lowercased() == "pdf" {
                        NotificationCenter.default.post(name: .zzPDFOpenDocument, object: url)
                    } else {
                        workspace.addImageFiles([url])
                    }
                }
            }
        }
        return handled
    }

    var body: some View {
        VStack(spacing: 0) {
            mainContent
            statusBar
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar { appToolbar }
        .sheet(isPresented: $workspace.showSignaturePad) {
            SignatureSheet(strokes: $workspace.savedSignature)
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showPasswordExport) {
            PasswordExportSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showOCRResult) {
            OCRResultSheet(text: $workspace.ocrText)
        }
        .sheet(isPresented: $workspace.showNoteEditor) {
            NoteEditorSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showFreeTextEditor) {
            FreeTextEditorSheet()
                .environmentObject(workspace)
        }
        .onOpenURL { url in
            guard url.pathExtension.lowercased() == "pdf" else { return }
            NotificationCenter.default.post(name: .zzPDFOpenDocument, object: url)
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            receiveDroppedFiles(providers)
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [9, 6]))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
            NSWindow.allowsAutomaticWindowTabbing = true
            NSApp.keyWindow?.tabbingMode = .preferred
        }
        .onDisappear { workspace.flushTemporaryAutosave() }
        .navigationTitle(workspace.hasDocument ? workspace.displayName : "zzPDF")
    }

    @ViewBuilder
    private var mainContent: some View {
        if workspace.hasDocument {
            HSplitView {
                if workspace.sidebarVisible { PageSidebar() }
                PDFCanvas()
                    .environmentObject(workspace)
                    .frame(minWidth: 480)
                if workspace.inspectorVisible { InspectorPanel() }
            }
        } else {
            WelcomeView()
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(workspace.isDirty ? Color.orange : Color.green)
                .frame(width: 7, height: 7)
            Text(workspace.statusMessage)
                .lineLimit(1)
            Spacer()
            if workspace.hasDocument {
                Text("Page \(min(workspace.currentPageIndex + 1, workspace.pageCount)) of \(workspace.pageCount)")
                    .foregroundStyle(.secondary)
                Divider().frame(height: 12)
                Button { workspace.zoom(by: 0.85) } label: { Image(systemName: "minus.magnifyingglass") }
                    .buttonStyle(.plain)
                Button { workspace.fitPage() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.plain)
                    .help("Fit Page")
                Button { workspace.zoom(by: 1.18) } label: { Image(systemName: "plus.magnifyingglass") }
                    .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(.bar)
    }

    @ToolbarContentBuilder
    private var appToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { workspace.sidebarVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
            }
            .help("Thumbnails")
            Button { workspace.openDocument() } label: {
                Image(systemName: "folder")
            }
            .help("Open PDF")
            Button { workspace.save() } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(!workspace.hasDocument)
            .help("Save")
            Button { workspace.exportFlattened() } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .disabled(!workspace.hasDocument)
            .help("Export Flattened Copy")
        }
        ToolbarItem(placement: .principal) {
            if workspace.hasDocument {
                ToolPicker()
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            PageLayoutMenu()
            SearchField()
                .frame(width: 210)
            Button { workspace.inspectorVisible.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Inspector")
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @State private var hovering = false

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            VStack(spacing: 22) {
                ZStack {
                    RoundedRectangle(cornerRadius: 25)
                        .fill(Color.accentColor.gradient)
                        .frame(width: 92, height: 92)
                        .shadow(color: Color.accentColor.opacity(0.25), radius: 18, y: 8)
                    Image(systemName: "doc.richtext.fill")
                        .font(.system(size: 43, weight: .medium))
                        .foregroundStyle(.white)
                }
                VStack(spacing: 8) {
                    Text("zzPDF")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Everything you need to work with PDFs, without the clutter.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 12) {
                    Button("Open a PDF…") { workspace.openDocument() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    Button("Create from Images…") { workspace.importImages() }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                }
                HStack(spacing: 26) {
                    WelcomeFeature(icon: "highlighter", text: "Annotate")
                    WelcomeFeature(icon: "signature", text: "Sign")
                    WelcomeFeature(icon: "rectangle.3.group", text: "Organize")
                    WelcomeFeature(icon: "lock.shield", text: "Protect")
                }
                .padding(.top, 12)
            }
            .padding(60)
        }
    }
}

struct WelcomeFeature: View {
    let icon: String
    let text: String
    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: icon).font(.title2).foregroundStyle(.tint)
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
        .frame(width: 70)
    }
}

struct ToolPicker: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    var body: some View {
        HStack(spacing: 2) {
            ForEach(CanvasTool.allCases) { tool in
                if tool == .highlight {
                    MarkupToolPicker()
                } else if tool == .rectangle {
                    ShapeToolPicker()
                } else if tool != .underline && tool != .strikeOut && tool != .oval {
                    Button {
                        if tool == .signature && !workspace.hasSignature {
                            workspace.showSignaturePad = true
                        }
                        workspace.activateTool(tool)
                    } label: {
                        Image(systemName: tool.symbol)
                            .frame(width: 24, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(ToolButtonStyle(selected: workspace.activeTool == tool))
                    .help(tool.label)
                }
            }
        }
        .padding(3)
        .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct MarkupToolPicker: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @State private var preferredTool: CanvasTool = .highlight

    private var displayedTool: CanvasTool {
        workspace.activeTool.markupKind == nil ? preferredTool : workspace.activeTool
    }

    var body: some View {
        Menu {
            markupChoice(.highlight)
            markupChoice(.underline)
            markupChoice(.strikeOut)
        } label: {
            SubtoolMenuLabel(symbol: displayedTool.symbol, selected: workspace.activeTool.markupKind != nil)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Text Markup: \(displayedTool.label)")
        .onChange(of: workspace.activeTool) { _, tool in
            if tool.markupKind != nil { preferredTool = tool }
        }
    }

    @ViewBuilder
    private func markupChoice(_ tool: CanvasTool) -> some View {
        Button {
            preferredTool = tool
            workspace.activateTool(tool)
        } label: {
            Label(tool.label, systemImage: tool.symbol)
        }
    }
}

struct ShapeToolPicker: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    private var isSelected: Bool {
        workspace.activeTool == .rectangle || workspace.activeTool == .oval
    }

    var body: some View {
        Menu {
            Button {
                workspace.activateTool(.rectangle)
            } label: {
                Label("Rectangle", systemImage: "rectangle")
            }
            Button {
                workspace.activateTool(.oval)
            } label: {
                Label("Ellipse", systemImage: "circle")
            }
        } label: {
            SubtoolMenuLabel(symbol: "square.on.circle", selected: isSelected)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isSelected ? workspace.activeTool.label : "Shapes")
    }
}

struct SubtoolMenuLabel: View {
    let symbol: String
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: symbol)
                .frame(width: 24, height: 22)
            Image(systemName: "chevron.down")
                .font(.system(size: 5, weight: .bold))
                .offset(x: 1, y: 1)
        }
        .frame(width: 28, height: 22)
        .foregroundStyle(selected ? Color.white : Color.primary)
        .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
}

struct ToolButtonStyle: ButtonStyle {
    let selected: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background(selected ? Color.accentColor : Color.clear, in: RoundedRectangle(cornerRadius: 6))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

struct PageLayoutMenu: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        Menu {
            ForEach(PageLayoutMode.allCases) { layout in
                Button {
                    workspace.setPageLayout(layout)
                } label: {
                    Label(layout.label, systemImage: workspace.pageLayout == layout ? "checkmark" : layout.symbol)
                }
            }
            Divider()
            Button("Fit Page") { workspace.fitPage() }
            Button("Actual Size") { workspace.actualSize() }
        } label: {
            Image(systemName: workspace.pageLayout.symbol)
        }
        .help("Page Layout")
        .disabled(!workspace.hasDocument)
    }
}

struct SearchField: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            FocusableSearchTextField(
                text: $workspace.searchText,
                focusRequest: workspace.searchFocusRequest,
                onSubmit: workspace.submitSearch
            )
            if !workspace.searchText.isEmpty {
                Text("\(workspace.searchResults.isEmpty ? 0 : workspace.searchIndex + 1)/\(workspace.searchResults.count)")
                    .font(.caption2).foregroundStyle(.secondary)
                Button { workspace.nextSearchResult(direction: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(.plain)
                Button { workspace.nextSearchResult(direction: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(.plain)
                Button {
                    workspace.searchText = ""
                    workspace.updateSearch()
                } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
    }
}

struct FocusableSearchTextField: NSViewRepresentable {
    @Binding var text: String
    let focusRequest: Int
    let onSubmit: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = "Search"
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.submit)
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        guard focusRequest != context.coordinator.lastFocusRequest else { return }
        context.coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak field] in
            guard let field else { return }
            field.window?.makeFirstResponder(field)
            field.currentEditor()?.selectAll(nil)
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FocusableSearchTextField
        var lastFocusRequest = 0

        init(parent: FocusableSearchTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        @objc func submit() {
            let direction = NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1
            parent.onSubmit(direction)
        }
    }
}
