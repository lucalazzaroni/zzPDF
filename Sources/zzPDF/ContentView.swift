import AppKit
import PDFKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var workspace: PDFWorkspace

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
            workspace.load(url)
        }
        .onAppear { NSWindow.allowsAutomaticWindowTabbing = false }
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
        }
        ToolbarItem(placement: .principal) {
            if workspace.hasDocument {
                ToolPicker()
            } else {
                Text("zzPDF").fontWeight(.semibold)
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
                } else if tool != .underline && tool != .strikeOut {
                    Button {
                        if tool == .signature && !workspace.hasSignature {
                            workspace.showSignaturePad = true
                        }
                        workspace.activeTool = tool
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
        HStack(spacing: 0) {
            Button {
                workspace.activeTool = preferredTool
            } label: {
                Image(systemName: displayedTool.symbol)
                    .frame(width: 24, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(displayedTool.label)

            Menu {
                markupChoice(.highlight)
                markupChoice(.underline)
                markupChoice(.strikeOut)
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .frame(width: 12, height: 22)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose Text Markup Tool")
        }
        .foregroundStyle(workspace.activeTool.markupKind != nil ? Color.white : Color.primary)
        .background(
            workspace.activeTool.markupKind != nil ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .onChange(of: workspace.activeTool) { _, tool in
            if tool.markupKind != nil { preferredTool = tool }
        }
    }

    @ViewBuilder
    private func markupChoice(_ tool: CanvasTool) -> some View {
        Button {
            preferredTool = tool
            workspace.activeTool = tool
        } label: {
            Label(tool.label, systemImage: tool.symbol)
        }
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
            TextField("Search", text: $workspace.searchText)
                .textFieldStyle(.plain)
                .onSubmit { workspace.updateSearch() }
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
