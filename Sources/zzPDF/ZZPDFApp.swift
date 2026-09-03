import SwiftUI

@main
struct ZZPDFApp: App {
    @StateObject private var document = PDFWorkspace()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(document)
                .frame(minWidth: 980, minHeight: 680)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            AppCommands(document: document)
        }
    }
}

struct AppCommands: Commands {
    @ObservedObject var document: PDFWorkspace

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Apri PDF…") { document.openDocument() }
                .keyboardShortcut("o")
            Button("Importa immagini…") { document.importImages() }
        }
        CommandGroup(after: .saveItem) {
            Button("Salva") { document.save() }
                .keyboardShortcut("s")
                .disabled(!document.hasDocument)
            Button("Salva con nome…") { document.saveAs() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!document.hasDocument)
            Divider()
            Button("Esporta copia appiattita…") { document.exportFlattened() }
                .disabled(!document.hasDocument)
            Button("Esporta protetta…") { document.showPasswordExport = true }
                .disabled(!document.hasDocument)
        }
        CommandMenu("Pagine") {
            Button("Unisci un altro PDF…") { document.mergePDF() }
                .disabled(!document.hasDocument)
            Button("Estrai pagina corrente…") { document.extractCurrentPage() }
                .disabled(!document.hasDocument)
            Divider()
            Button("Ruota a sinistra") { document.rotateCurrentPage(by: -90) }
                .keyboardShortcut("l", modifiers: [.command, .option])
                .disabled(!document.hasDocument)
            Button("Ruota a destra") { document.rotateCurrentPage(by: 90) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!document.hasDocument)
            Button("Duplica pagina") { document.duplicateCurrentPage() }
                .disabled(!document.hasDocument)
            Button("Elimina pagina") { document.deleteCurrentPage() }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(!document.hasDocument)
        }
        CommandMenu("Annota") {
            Button("Evidenzia selezione") { document.addMarkup(.highlight) }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Sottolinea selezione") { document.addMarkup(.underline) }
            Button("Barra selezione") { document.addMarkup(.strikeOut) }
            Divider()
            Button("Crea firma…") { document.showSignaturePad = true }
            Button("Rimuovi annotazione selezionata") { document.removeSelectedAnnotation() }
                .keyboardShortcut(.delete, modifiers: [])
        }
        CommandMenu("Vista") {
            Button(document.sidebarVisible ? "Nascondi miniature" : "Mostra miniature") {
                document.sidebarVisible.toggle()
            }
            Button(document.inspectorVisible ? "Nascondi pannello strumenti" : "Mostra pannello strumenti") {
                document.inspectorVisible.toggle()
            }
            Divider()
            Button("Adatta pagina") { document.fitPage() }
                .keyboardShortcut("0", modifiers: [.command])
            Button("Dimensione reale") { document.actualSize() }
                .keyboardShortcut("1", modifiers: [.command])
        }
    }
}
