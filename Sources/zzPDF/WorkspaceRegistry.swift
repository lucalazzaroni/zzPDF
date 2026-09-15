import AppKit
import SwiftUI

/// Posted with a file URL when a document should be opened, from the Finder, a drop,
/// or the recent-documents menu.
extension Notification.Name {
    static let zzPDFOpenDocument = Notification.Name("zzPDFOpenDocument")
}


@MainActor
final class WorkspaceRegistry: ObservableObject {
    private let workspaces = NSHashTable<PDFWorkspace>.weakObjects()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private let delegateProxies = NSMapTable<NSWindow, DocumentWindowDelegateProxy>.weakToStrongObjects()
    private let workspacesByWindow = NSMapTable<NSWindow, PDFWorkspace>.weakToWeakObjects()
    private var didAssignInitialRestoration = false
    private weak var pendingTabHost: NSWindow?
    private var pendingDocumentURLs: [URL] = []
    private var restoreQueue: [RestoreItem] = []
    private var didOpenRestoreWindows = false
    private(set) var isTerminating = false

    /// What a window opened at launch should put on screen.
    enum RestoreItem {
        case recovery
        case session(AppPreferences.SessionDocument)
    }

    func register(_ workspace: PDFWorkspace) {
        workspaces.add(workspace)
    }

    func requestNewTab(in host: NSWindow?) {
        pendingTabHost = host
    }

    func configure(window: NSWindow, workspace: PDFWorkspace) {
        let isNewWindow = !configuredWindows.contains(window)
        configuredWindows.add(window)
        workspacesByWindow.setObject(workspace, forKey: window)
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

    /// Queues a file for the next window to open, so a document arriving from the Finder
    /// or a drop lands in its own window instead of replacing what is already on screen.
    func enqueueDocument(_ url: URL) {
        pendingDocumentURLs.append(url)
    }

    func dequeueDocument() -> URL? {
        pendingDocumentURLs.isEmpty ? nil : pendingDocumentURLs.removeFirst()
    }

    var hasPendingDocuments: Bool { !pendingDocumentURLs.isEmpty }

    func shouldRestoreInitialWindow() -> Bool {
        guard !didAssignInitialRestoration else { return false }
        didAssignInitialRestoration = true
        return true
    }

    /// Works out everything the app should reopen: unsaved work waiting in the recovery
    /// store first, then the documents that were on screen when it last quit. Runs once.
    func prepareRestoreQueue(preferences: AppPreferences, recoveryStore: TemporaryRecoveryStore? = nil) {
        guard shouldRestoreInitialWindow() else { return }
        let store = recoveryStore ?? .shared
        let recoveries = preferences.temporaryAutosave ? store.pendingRecords() : []
        restoreQueue = Array(repeating: .recovery, count: recoveries.count)
        guard preferences.restoreLastDocument else { return }
        let recovered = Set(recoveries.compactMap(\.originalPath))
        for document in preferences.sessionDocuments
        where !recovered.contains(document.path) && FileManager.default.fileExists(atPath: document.path) {
            restoreQueue.append(.session(document))
        }
    }

    func nextRestoreItem() -> RestoreItem? {
        restoreQueue.isEmpty ? nil : restoreQueue.removeFirst()
    }

    /// Opens one window for every document still waiting, once the first one is showing.
    func openWindowsForRemainingRestores(_ openWindow: (String) -> Void) {
        guard !didOpenRestoreWindows else { return }
        didOpenRestoreWindows = true
        for _ in restoreQueue { openWindow("document") }
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
        rememberFrontmostSession()
        flushTemporaryRecoveries()
    }

    /// Writes the session to restore next launch back to front, so the frontmost window
    /// wins. Without this a window closed earlier could have cleared the stored session
    /// while another document was still open.
    private func rememberFrontmostSession() {
        for window in NSApp.orderedWindows.reversed() {
            workspacesByWindow.object(forKey: window)?.rememberSessionForTermination()
        }
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
