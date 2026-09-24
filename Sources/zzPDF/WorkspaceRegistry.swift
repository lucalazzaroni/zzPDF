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
    /// Asks SwiftUI for another window in the document group. Set by each window as it
    /// appears, since only a view can reach the `openWindow` action.
    var requestNewWindow: (() -> Void)?
    private var openObserver: (any NSObjectProtocol)?

    init() {
        openObserver = NotificationCenter.default.addObserver(
            forName: .zzPDFOpenDocument,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            MainActor.assumeIsolated { self?.openDocument(at: url) }
        }
    }

    deinit {
        if let openObserver { NotificationCenter.default.removeObserver(openObserver) }
    }

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

    /// One window, as far as deciding where to open a document is concerned.
    struct Candidate: Equatable {
        /// The file that window is showing, if it is showing a file.
        let url: URL?
        /// Whether it has nothing open in it at all.
        let isEmpty: Bool
    }

    /// What to do with an open request.
    enum OpenOutcome: Equatable {
        /// The document is already on screen in this window; bring it forward.
        case front(Int)
        /// This window is empty, so the document goes in it.
        case loadInto(Int)
        /// Every window is taken; the document needs one of its own.
        case newWindow
    }

    /// Where a document should open, given the windows already on screen in order of
    /// preference. Kept apart from acting on it so the choice can be tested.
    static func outcome(for url: URL, among candidates: [Candidate]) -> OpenOutcome {
        let target = url.standardizedFileURL
        if let index = candidates.firstIndex(where: { $0.url?.standardizedFileURL == target }) {
            return .front(index)
        }
        if let index = candidates.firstIndex(where: \.isEmpty) {
            return .loadInto(index)
        }
        return .newWindow
    }

    /// Opens a document that arrived from the Finder, a drop, or the recent-documents menu.
    ///
    /// Everything routes through here, and only here, because an open request reaches every
    /// window at once: `onOpenURL` is part of the window's own view, and the notification it
    /// posts is a broadcast. Letting each window act on it opened one new window for every
    /// window already on screen.
    func openDocument(at url: URL) {
        let windows = orderedDocumentWindows()
        let candidates = windows.map { Candidate(url: $0.workspace.fileURL, isEmpty: !$0.workspace.hasDocument) }
        switch Self.outcome(for: url, among: candidates) {
        case .front(let index):
            // The file may already be open — at launch especially, where the window
            // restoring last session's document and the file being opened are usually the
            // same file. That is what put two windows of one document on screen, one
            // restored at its old size and one new.
            let window = windows[index].window
            window.tabGroup?.selectedWindow = window
            window.makeKeyAndOrderFront(nil)
        case .loadInto(let index):
            windows[index].workspace.load(url)
            windows[index].window.makeKeyAndOrderFront(nil)
        case .newWindow:
            enqueueDocument(url)
            requestNewWindow?()
        }
    }

    /// The window already showing `url`, if any.
    func window(showing url: URL) -> NSWindow? {
        let target = url.standardizedFileURL
        return orderedDocumentWindows()
            .first { $0.workspace.fileURL?.standardizedFileURL == target }?
            .window
    }

    /// Every window with a document in it, the key one first, since that is the one the
    /// reader is looking at.
    private func orderedDocumentWindows() -> [(window: NSWindow, workspace: PDFWorkspace)] {
        let key = NSApp.keyWindow
        let ordered = [key].compactMap { $0 } + NSApp.orderedWindows.filter { $0 !== key }
        return ordered.compactMap { window in
            guard let workspace = workspacesByWindow.object(forKey: window) else { return nil }
            return (window, workspace)
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
