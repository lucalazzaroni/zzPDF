import AppKit
import PDFKit
import SwiftUI

@main
@MainActor
struct SearchVisibilitySmoke {
    static func main() {
        _ = NSApplication.shared
        let suite = "it.lucalazzaroni.zzpdf.tests.searchvisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = AppPreferences(defaults: defaults)
        preferences.temporaryAutosave = false
        let workspace = PDFWorkspace(preferences: preferences)
        workspace.pdfDocument = PDFDocument()
        let page = PDFPage()
        page.setBounds(CGRect(x: 0, y: 0, width: 595, height: 842), for: .mediaBox)
        workspace.pdfDocument?.insert(page, at: 0)
        let registry = WorkspaceRegistry()
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 680),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ContentView()
            .environmentObject(workspace).environmentObject(preferences).environmentObject(registry))
        window.makeKeyAndOrderFront(nil)
        settle()

        for initiallyVisible in [true, false] {
            workspace.sidebarVisible = initiallyVisible
            settle()
            workspace.focusSearch()
            settle()
            guard let root = window.contentView,
                  let field = descendants(root).compactMap({ $0 as? NSTextField })
                    .first(where: { $0.placeholderString == "Search" }),
                  field.window === window, !field.visibleRect.isEmpty,
                  let editor = field.currentEditor(), window.firstResponder === editor else {
                fatalError("Command-F did not expose and focus Search at 980pt with sidebar visible=\(initiallyVisible)")
            }
        }
        window.orderOut(nil)
        print("Search visibility smoke test passed: narrow window and initially hidden sidebar.")
    }

    static func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    static func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
    }
}
