import AppKit
import SwiftUI

@MainActor
final class WorkspaceRegistry: ObservableObject {
    private let workspaces = NSHashTable<PDFWorkspace>.weakObjects()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private var didAssignInitialRestoration = false
    private weak var pendingTabHost: NSWindow?

    func register(_ workspace: PDFWorkspace) {
        workspaces.add(workspace)
    }

    func requestNewTab(in host: NSWindow?) {
        pendingTabHost = host
    }

    func configure(window: NSWindow, workspace: PDFWorkspace) {
        let isNewWindow = !configuredWindows.contains(window)
        configuredWindows.add(window)
        register(workspace)

        window.tabbingMode = .preferred
        window.tabbingIdentifier = "it.lucalazzaroni.zzpdf.documents"
        window.title = workspace.hasDocument ? workspace.displayName : "zzPDF"
        window.representedURL = workspace.fileURL
        window.isDocumentEdited = workspace.isDirty

        if isNewWindow,
           let host = pendingTabHost,
           host !== window {
            pendingTabHost = nil
            host.tabbingMode = .preferred
            host.tabbingIdentifier = window.tabbingIdentifier
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    func shouldRestoreInitialWindow() -> Bool {
        guard !didAssignInitialRestoration else { return false }
        didAssignInitialRestoration = true
        return true
    }

    func applyPreferencesToOpenDocuments() {
        for workspace in workspaces.allObjects {
            workspace.applyDefaultPreferences()
        }
    }

    func flushTemporaryRecoveries() {
        for workspace in workspaces.allObjects {
            workspace.flushTemporaryAutosave()
        }
    }
}

struct DocumentWindowAccessor: NSViewRepresentable {
    @ObservedObject var workspace: PDFWorkspace
    let registry: WorkspaceRegistry

    func makeNSView(context: Context) -> NSView {
        NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            registry.configure(window: window, workspace: workspace)
        }
    }
}
