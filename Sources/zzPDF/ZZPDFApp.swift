import SwiftUI

@main
struct ZZPDFApp: App {
    @StateObject private var preferences: AppPreferences
    @StateObject private var document: PDFWorkspace

    init() {
        let preferences = AppPreferences()
        _preferences = StateObject(wrappedValue: preferences)
        _document = StateObject(wrappedValue: PDFWorkspace(preferences: preferences))
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .environmentObject(preferences)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.automatic)
        .commands {
            AppCommands(document: document)
        }
        Settings {
            SettingsView()
                .environmentObject(document)
                .environmentObject(preferences)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var document: PDFWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Open PDF…") { document.openDocument() }
                .keyboardShortcut("o")
            Button("Import Images…") { document.importImages() }
        }
        CommandGroup(replacing: .undoRedo) {
            Button("Undo") { document.undo() }
                .keyboardShortcut("z")
                .disabled(!document.canUndo)
            Button("Redo") { document.redo() }
                .keyboardShortcut("y", modifiers: [.command])
                .disabled(!document.canRedo)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Find…") { document.focusSearch() }
                .keyboardShortcut("f", modifiers: [.command])
        }
        CommandGroup(after: .saveItem) {
            Button("Save") { document.save() }
                .keyboardShortcut("s")
                .disabled(!document.hasDocument)
            Button("Save As…") { document.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!document.hasDocument)
            Divider()
            Button("Export Flattened Copy…") { document.exportFlattened() }
                .disabled(!document.hasDocument)
            Button("Export Protected Copy…") { document.showPasswordExport = true }
                .disabled(!document.hasDocument)
        }
        CommandMenu("Pages") {
            Button("Merge Another PDF…") { document.mergePDF() }
                .disabled(!document.hasDocument)
            Button("Extract Current Page…") { document.extractCurrentPage() }
                .disabled(!document.hasDocument)
            Divider()
            Button("Rotate Left") { document.rotateCurrentPage(by: -90) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!document.hasDocument)
            Button("Rotate Right") { document.rotateCurrentPage(by: 90) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!document.hasDocument)
            Button("Duplicate Page") { document.duplicateCurrentPage() }
                .disabled(!document.hasDocument)
            Button("Delete Page") { document.deleteCurrentPage() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!document.hasDocument)
        }
        CommandMenu("Annotate") {
            Button("Select Tool") { document.activateSelectTool() }
                .keyboardShortcut(.escape, modifiers: [])
            Divider()
            Button("Highlight Selection") { document.addMarkup(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Underline Selection") { document.addMarkup(.underline) }
            Button("Strike Through Selection") { document.addMarkup(.strikeOut) }
            Divider()
            Button("Create Signature…") { document.showSignaturePad = true }
            Button("Import Signature Image…") { document.importSignatureImage() }
            Button("Remove Selected Annotation") { document.removeSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        CommandMenu("PDF View") {
            ForEach(PageLayoutMode.allCases) { layout in
                Button(layout.label) { document.setPageLayout(layout) }
            }
            Divider()
            Button(document.sidebarVisible ? "Hide Thumbnails" : "Show Thumbnails") {
                document.sidebarVisible.toggle()
            }
            Button(document.inspectorVisible ? "Hide Inspector" : "Show Inspector") {
                document.inspectorVisible.toggle()
            }
            Divider()
            Button("Fit Page") { document.fitPage() }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Actual Size") { document.actualSize() }
                .keyboardShortcut("1", modifiers: [.command])
        }
    }
}
