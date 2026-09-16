import AppKit
import SwiftUI

@main
struct ZZPDFApp: App {
    @StateObject private var preferences = AppPreferences()
    @StateObject private var registry = WorkspaceRegistry()

    var body: some Scene {
        WindowGroup("zzPDF", id: "document") {
            DocumentWindow(preferences: preferences, registry: registry)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.automatic)
        .commands { AppCommands(registry: registry, preferences: preferences) }
        Settings {
            SettingsView()
                .environmentObject(preferences)
                .environmentObject(registry)
        }
    }
}

private struct DocumentWindow: View {
    @ObservedObject var preferences: AppPreferences
    @ObservedObject var registry: WorkspaceRegistry
    @StateObject private var workspace: PDFWorkspace
    @Environment(\.openWindow) private var openWindow

    init(preferences: AppPreferences, registry: WorkspaceRegistry) {
        self.preferences = preferences
        self.registry = registry
        _workspace = StateObject(wrappedValue: PDFWorkspace(preferences: preferences))
    }

    var body: some View {
        ContentView()
            .environmentObject(workspace)
            .environmentObject(preferences)
            .focusedSceneObject(workspace)
            .frame(minWidth: 980, minHeight: 680)
            .background(DocumentWindowAccessor(workspace: workspace, registry: registry))
            .onAppear {
                registry.register(workspace)
                if let url = registry.dequeueDocument() {
                    workspace.load(url)
                    return
                }
                registry.prepareRestoreQueue(preferences: preferences)
                if let item = registry.nextRestoreItem() {
                    workspace.restore(item)
                }
                registry.openWindowsForRemainingRestores { openWindow(id: $0) }
            }
            .onReceive(NotificationCenter.default.publisher(for: .zzPDFOpenDocument)) { notification in
                guard let url = notification.object as? URL else { return }
                guard workspace.hasDocument else {
                    workspace.load(url)
                    return
                }
                registry.enqueueDocument(url)
                openWindow(id: "document")
            }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                registry.prepareForTermination()
            }
    }
}

struct AppCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var document: PDFWorkspace?
    @ObservedObject var registry: WorkspaceRegistry
    @ObservedObject var preferences: AppPreferences

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(id: "document") }
                .keyboardShortcut("n", modifiers: [.command])
            Button("New Tab") { createTab() }
                .keyboardShortcut("t", modifiers: [.command])
            Divider()
            Button("Open PDF…") { document?.openDocument() }
                .keyboardShortcut("o")
                .disabled(document == nil)
            Menu("Open Recent") {
                let recents = preferences.recentDocumentURLs
                ForEach(recents, id: \.self) { url in
                    Button(url.deletingPathExtension().lastPathComponent) {
                        NotificationCenter.default.post(name: .zzPDFOpenDocument, object: url)
                    }
                }
                if !recents.isEmpty {
                    Divider()
                    Button("Clear Menu") { preferences.clearRecentDocuments() }
                }
            }
            .disabled(preferences.recentDocumentURLs.isEmpty)
            .id(preferences.recentDocumentsToken)
            Button("Import Images…") { document?.importImages() }
                .disabled(document == nil)
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { document?.undo() }
                .keyboardShortcut("z")
                .disabled(document?.canUndo != true)
            Button("Redo") { document?.redo() }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(document?.canRedo != true)
        }
        CommandGroup(replacing: .appTermination) {
            Button("Quit zzPDF") {
                registry.prepareForTermination()
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: [.command])
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { document?.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])
                .disabled(document?.hasDocument != true)
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { document?.save() }
                .keyboardShortcut("s")
                .disabled(document?.hasDocument != true)
            Button("Save As…") { document?.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(document?.hasDocument != true)
            Divider()
            Button("Export Flattened Copy…") { document?.exportFlattened() }
                .disabled(document?.hasDocument != true)
            Button("Export Protected Copy…") { document?.showPasswordExport = true }
                .disabled(document?.hasDocument != true)
            Button("Export Unprotected Copy…") { document?.removePasswordProtection() }
                .disabled(document?.isPasswordProtected != true)
            Button("Page Numbers & Headers…") { document?.beginPageStamp(PageStamper.Options()) }
                .disabled(document?.hasDocument != true)
            Button("Watermark…") { document?.beginPageStamp(.watermark) }
                .disabled(document?.hasDocument != true)
            Divider()
            Button("Export Pages as Images…") { document?.exportPagesAsImages() }
                .disabled(document?.hasDocument != true)
            Button("Export Smaller Copy…") { document?.exportSmallerCopy() }
                .disabled(document?.hasDocument != true)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { document?.printDocument() }
                .keyboardShortcut("p", modifiers: [.command])
                .disabled(document?.hasDocument != true)
        }
        CommandMenu("Pages") {
            Button("Merge Another PDF…") { document?.mergePDF() }
                .disabled(document?.hasDocument != true)
            Button("Extract Selected Pages…") { document?.extractSelectedPages() }
                .disabled(document?.hasDocument != true)
            Button("Split Document…") { document?.beginSplit() }
                .disabled(document?.hasDocument != true)
            Button("Compare with Another PDF…") { document?.compareWithAnotherPDF() }
                .disabled(document?.hasDocument != true)
            Divider()
            Button("Rotate Left") { document?.rotateSelectedPages(by: -90) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(document?.hasDocument != true)
            Button("Rotate Right") { document?.rotateSelectedPages(by: 90) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(document?.hasDocument != true)
            Button("Duplicate Pages") { document?.duplicateSelectedPages() }
                .disabled(document?.hasDocument != true)
            Button("Delete Pages") { document?.deleteSelectedPages() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(document?.hasDocument != true)
        }
        CommandMenu("Annotate") {
            Button("Select Tool") { document?.activateSelectTool() }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(document == nil)
            Button("Edit Text Tool") { document?.activateTool(.editText) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(document?.hasDocument != true)
            Divider()
            Button("Highlight Selection") { document?.addMarkup(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(document?.hasDocument != true)
            Button("Underline Selection") { document?.addMarkup(.underline) }
                .disabled(document?.hasDocument != true)
            Button("Strike Through Selection") { document?.addMarkup(.strikeOut) }
                .disabled(document?.hasDocument != true)
            Divider()
            Button("Create Signature…") { document?.showSignaturePad = true }
                .disabled(document?.hasDocument != true)
            Button("Import Signature Image…") { document?.importSignatureImage() }
                .disabled(document?.hasDocument != true)
            Button("Remove Selected Annotation") { document?.removeSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(document?.selectedAnnotation == nil)
        }
        CommandMenu("PDF View") {
            ForEach(PageLayoutMode.allCases) { layout in
                Button(layout.label) { document?.setPageLayout(layout) }
                    .disabled(document?.hasDocument != true)
            }
            Divider()
            Button(document?.sidebarVisible == true ? "Hide Thumbnails" : "Show Thumbnails") {
                document?.sidebarVisible.toggle()
            }
            .disabled(document == nil)
            Button(document?.inspectorVisible == true ? "Hide Inspector" : "Show Inspector") {
                document?.inspectorVisible.toggle()
            }
            .disabled(document == nil)
            Divider()
            ForEach(ReadingMode.allCases) { mode in
                Button(mode.label) { document?.setReadingMode(mode) }
                    .disabled(document == nil)
            }
            Divider()
            Button("Fit Page") { document?.fitPage() }
                .keyboardShortcut("0", modifiers: [.command])
                .disabled(document?.hasDocument != true)
            Button("Actual Size") { document?.actualSize() }
                .keyboardShortcut("1", modifiers: [.command])
                .disabled(document?.hasDocument != true)
        }
    }

    private func createTab() {
        registry.requestNewTab(in: NSApp.keyWindow)
        openWindow(id: "document")
    }
}
