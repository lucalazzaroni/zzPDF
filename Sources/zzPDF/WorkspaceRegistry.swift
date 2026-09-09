import AppKit
import SwiftUI

@MainActor
final class WorkspaceRegistry: ObservableObject {
    private let workspaces = NSHashTable<PDFWorkspace>.weakObjects()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private let delegateProxies = NSMapTable<NSWindow, DocumentWindowDelegateProxy>.weakToStrongObjects()
    private var didAssignInitialRestoration = false
    private weak var pendingTabHost: NSWindow?
    private(set) var isTerminating = false

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

        if delegateProxies.object(forKey: window) == nil {
            let proxy = DocumentWindowDelegateProxy(
                originalDelegate: window.delegate,
                workspace: workspace,
                registry: self
            )
            delegateProxies.setObject(proxy, forKey: window)
            window.delegate = proxy
        }

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
            workspace.prepareForApplicationTermination()
        }
    }

    func prepareForTermination() {
        isTerminating = true
        flushTemporaryRecoveries()
    }

    func shouldClose(window: NSWindow, workspace: PDFWorkspace) -> Bool {
        if isTerminating {
            workspace.prepareForApplicationTermination()
            return true
        }
        return workspace.confirmDeliberateClose()
    }
}

private final class DocumentWindowDelegateProxy: NSObject, NSWindowDelegate {
    private weak var originalDelegate: NSWindowDelegate?
    private weak var workspace: PDFWorkspace?
    private weak var registry: WorkspaceRegistry?

    init(
        originalDelegate: NSWindowDelegate?,
        workspace: PDFWorkspace,
        registry: WorkspaceRegistry
    ) {
        self.originalDelegate = originalDelegate
        self.workspace = workspace
        self.registry = registry
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard originalDelegate?.windowShouldClose?(sender) ?? true else { return false }
        guard let workspace, let registry else { return true }
        return registry.shouldClose(window: sender, workspace: workspace)
    }

    override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || originalDelegate?.responds(to: selector) == true
    }

    override func forwardingTarget(for selector: Selector!) -> Any? {
        if originalDelegate?.responds(to: selector) == true {
            return originalDelegate
        }
        return super.forwardingTarget(for: selector)
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
