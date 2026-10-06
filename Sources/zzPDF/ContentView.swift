import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @EnvironmentObject private var registry: WorkspaceRegistry
    @State private var dropTargeted = false

    /// Accepts PDFs and images dropped on the window: a PDF opens like any other
    /// document, images are added as pages.
    private func receiveDroppedFiles(_ providers: [NSItemProvider]) -> Bool {
        let identifier = UTType.fileURL.identifier
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier(identifier) {
            handled = true
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil),
                      url.isFileURL else { return }
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
        .sheet(isPresented: $workspace.showPageStamp) {
            PageStampSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showComparison) {
            ComparisonSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showSplit) {
            SplitSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showPasswordExport) {
            PasswordExportSheet()
                .environmentObject(workspace)
        }
        .sheet(isPresented: $workspace.showOCRResult) {
            OCRResultSheet(text: $workspace.ocrText)
        }
        .sheet(isPresented: $workspace.showAutoFill) {
            AutoFillSheet()
                .environmentObject(workspace)
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
        .navigationTitle(WorkspaceRegistry.windowTitle(workspace.hasDocument ? workspace.displayName : "zzPDF"))
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
        } else if !workspace.isSettling, registry.shouldOfferWelcome {
            WelcomeView()
        } else {
            // Something is on its way into this window — a file being opened, or a document
            // reopening from last time. The welcome screen would only be in the way of it.
            Color(nsColor: .windowBackgroundColor)
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
            Button { workspace.focusSearch() } label: {
                Image(systemName: "magnifyingglass")
            }
            .help("Find in PDF (Command-F)")
            .disabled(!workspace.hasDocument)
            Button { workspace.inspectorVisible.toggle() } label: {
                Image(systemName: "sidebar.right")
            }
            .help("Inspector")
        }
    }
}

struct WelcomeView: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(nsColor: .windowBackgroundColor), Color.accentColor.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            ScrollView {
            VStack(spacing: 24) {
                // The app's own icon, rather than a drawing of one: a second version of it
                // here is a second version to keep in step, and it had already drifted.
                Image(nsImage: NSApp?.applicationIconImage
                    ?? NSImage(named: NSImage.applicationIconName)
                    ?? NSImage())
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
                    .shadow(color: .black.opacity(0.18), radius: 14, y: 6)
                VStack(spacing: 8) {
                    Text("zzPDF")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                    Text("Edit the text. Make it yours.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text("A complete PDF workspace, right on your Mac.")
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
                if !workspace.preferences.recentDocumentURLs.isEmpty {
                    VStack(spacing: 6) {
                        Text("RECENT")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(workspace.preferences.recentDocumentURLs.prefix(5), id: \.self) { url in
                            Button {
                                NotificationCenter.default.post(name: .zzPDFOpenDocument, object: url)
                            } label: {
                                Label(url.deletingPathExtension().lastPathComponent, systemImage: "doc")
                                    .lineLimit(1)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.top, 4)
                }
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                    WelcomeFeature(icon: "text.cursor", text: "Edit text", detail: "Rewrite existing text or add your own.")
                    WelcomeFeature(icon: "highlighter", text: "Annotate & draw", detail: "Highlight, underline, add notes and shapes.")
                    WelcomeFeature(icon: "signature", text: "Fill & sign", detail: "Complete forms and add your graphic signature.")
                    WelcomeFeature(icon: "rectangle.3.group", text: "Organize pages", detail: "Merge, split, reorder, crop and rotate.")
                    WelcomeFeature(icon: "doc.text.viewfinder", text: "Search & compare", detail: "Make scans searchable with OCR. Compare PDFs.")
                    WelcomeFeature(icon: "square.and.arrow.up", text: "Finish & share", detail: "Watermarks, page numbers, redaction and export.")
                }
                .padding(.top, 4)
                Label("On your Mac. Your documents stay with you.", systemImage: "lock.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: 760)
            .padding(.horizontal, 36)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
            }
        }
    }
}

struct WelcomeFeature: View {
    let icon: String
    let text: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 21, weight: .medium))
                .foregroundStyle(.tint)
                .frame(height: 26)
                .accessibilityHidden(true)
            Text(text).font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .padding(16)
        .background(.background.opacity(0.65), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.primary.opacity(0.06)))
        .accessibilityElement(children: .combine)
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
                } else if tool == .line {
                    LineToolPicker()
                } else if tool != .underline && tool != .strikeOut && tool != .oval
                            && tool != .arrow && tool != .polygon {
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

struct LineToolPicker: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    private var isSelected: Bool {
        workspace.activeTool.isLineTool || workspace.activeTool == .polygon
    }

    var body: some View {
        Menu {
            Button { workspace.activateTool(.line) } label: { Label("Line", systemImage: "line.diagonal") }
            Button { workspace.activateTool(.arrow) } label: { Label("Arrow", systemImage: "line.diagonal.arrow") }
            Button { workspace.activateTool(.polygon) } label: { Label("Polygon", systemImage: "pentagon") }
        } label: {
            SubtoolMenuLabel(
                symbol: isSelected ? workspace.activeTool.symbol : "line.diagonal.arrow",
                selected: isSelected
            )
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(isSelected ? workspace.activeTool.label : "Lines and Shapes")
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
                if workspace.isSearching {
                    ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 12, height: 12)
                }
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
