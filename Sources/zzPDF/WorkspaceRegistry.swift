import AppKit
import SwiftUI

/// Posted with a file URL when a document should be opened, from the Finder, a drop,
/// or the recent-documents menu.
extension Notification.Name {
    static let zzPDFOpenDocument = Notification.Name("zzPDFOpenDocument")
    /// Posted once AppKit has finished launching the app.
    static let zzPDFDidFinishLaunching = Notification.Name("zzPDFDidFinishLaunching")
}


@MainActor
final class WorkspaceRegistry: ObservableObject {
    private let workspaces = NSHashTable<PDFWorkspace>.weakObjects()
    private let configuredWindows = NSHashTable<NSWindow>.weakObjects()
    private let delegateProxies = NSMapTable<NSWindow, DocumentWindowDelegateProxy>.weakToStrongObjects()
    private let workspacesByWindow = NSMapTable<NSWindow, PDFWorkspace>.weakToWeakObjects()
    private var didAssignInitialRestoration = false
    /// How many windows still on their way were asked for as windows in their own right.
    ///
    /// Tabbing is what happens otherwise. A document the reader asked for belongs beside
    /// what they are already reading, and most windows are not asked for by the app at all
    /// — SwiftUI makes one of its own for a file opened while the app is running — so
    /// marking the ones we ask for was marking the wrong half.
    private(set) var standaloneWindowsPending = 0
    @Published private var pendingDocumentURLs: [URL] = []
    @Published private var restoreQueue: [RestoreItem] = []
    private var didOpenRestoreWindows = false
    /// Cleared once AppKit says the launch is over, which is the first moment the app can
    /// know whether it was started to open a file.
    @Published private(set) var isLaunching = true
    private var openedDuringLaunch = false
    private weak var preferences: AppPreferences?
    private var recoveryStore: TemporaryRecoveryStore?
    private(set) var isTerminating = false
    /// Asks SwiftUI for another window in the document group. Set by each window as it
    /// appears, since only a view can reach the `openWindow` action.
    var requestNewWindow: (() -> Void)?
    private var openObserver: (any NSObjectProtocol)?
    private var launchObserver: (any NSObjectProtocol)?

    init() {
        openObserver = NotificationCenter.default.addObserver(
            forName: .zzPDFOpenDocument,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            MainActor.assumeIsolated { self?.openDocument(at: url) }
        }
        launchObserver = NotificationCenter.default.addObserver(
            forName: .zzPDFDidFinishLaunching,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidFinishLaunching() }
        }
    }

    deinit {
        if let openObserver { NotificationCenter.default.removeObserver(openObserver) }
        if let launchObserver { NotificationCenter.default.removeObserver(launchObserver) }
    }

    /// What a window opened at launch should put on screen.
    enum RestoreItem {
        case recovery
        case session(AppPreferences.SessionDocument)
    }

    func register(_ workspace: PDFWorkspace) {
        workspaces.add(workspace)
    }

    /// Says that the next window to appear is a window, not another tab.
    ///
    /// Said before the window is asked for, because a window is configured well after the
    /// asking and there is nothing to attach it to in between.
    func willOpenStandaloneWindow() {
        standaloneWindowsPending += 1
    }

    /// Asks for somewhere to put a document: another tab of what is already open.
    func requestWindow() {
        requestNewWindow?()
    }

    func configure(window: NSWindow, workspace: PDFWorkspace) {
        let isNewWindow = !configuredWindows.contains(window)
        configuredWindows.add(window)
        workspacesByWindow.setObject(workspace, forKey: window)
        register(workspace)

        window.tabbingMode = .preferred
        window.tabbingIdentifier = "it.lucalazzaroni.zzpdf.documents"
        let name = workspace.hasDocument ? workspace.displayName : "zzPDF"
        window.title = Self.windowTitle(name)
        // The tab bar is AppKit's and takes no margins from us. A name too long for its
        // tab is set flush against the divider beside it, so the tab is given a shorter
        // name of its own with room to breathe.
        window.tab.title = " " + Self.shortened(name) + " "
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

        if isNewWindow, let host = host(besides: window) {
            guard standaloneWindowsPending == 0 else {
                standaloneWindowsPending -= 1
                return
            }
            host.tabbingMode = .preferred
            host.tabbingIdentifier = window.tabbingIdentifier
            host.addTabbedWindow(window, ordered: .above)
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// A document's name as the toolbar should carry it.
    ///
    /// AppKit sets the title hard against the divider that separates the sidebar's half of
    /// the toolbar from the document's, with a couple of points between them and no way to
    /// ask for more. Leading space in the title itself is the way to ask.
    static func windowTitle(_ name: String) -> String { "   " + name }

    /// A name short enough to sit inside a tab rather than fill it, keeping the beginning
    /// and the end, which is where documents differ from one another.
    static func shortened(_ name: String, limit: Int = 22) -> String {
        guard name.count > limit else { return name }
        let head = name.prefix((limit - 1) / 2)
        let tail = name.suffix(limit - 1 - head.count)
        return "\(head)…\(tail)"
    }

    /// The window a new tab should join: the one the reader is looking at, or failing that
    /// any other document window.
    private func host(besides window: NSWindow) -> NSWindow? {
        if let key = NSApp?.keyWindow, key !== window, configuredWindows.contains(key) { return key }
        return (NSApp?.orderedWindows ?? []).first { $0 !== window && configuredWindows.contains($0) }
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
        if isLaunching { openedDuringLaunch = true }
        let candidates = orderedWorkspaces()
        switch Self.outcome(for: url, among: candidates.map {
            Candidate(url: $0.fileURL, isEmpty: !$0.hasDocument)
        }) {
        case .front(let index):
            // The file may already be open — at launch especially, where the window
            // restoring last session's document and the file being opened are usually the
            // same file. That is what put two windows of one document on screen, one
            // restored at its old size and one new.
            if let window = window(for: candidates[index]) {
                window.tabGroup?.selectedWindow = window
                window.makeKeyAndOrderFront(nil)
            }
        case .loadInto(let index):
            candidates[index].load(url)
            window(for: candidates[index])?.makeKeyAndOrderFront(nil)
        case .newWindow:
            enqueueDocument(url)
            requestWindow()
        }
    }

    /// The window already showing `url`, if any.
    func window(showing url: URL) -> NSWindow? {
        let target = url.standardizedFileURL
        guard let workspace = workspaces.allObjects.first(where: {
            $0.fileURL?.standardizedFileURL == target
        }) else { return nil }
        return window(for: workspace)
    }

    /// Every workspace on screen, the key window's first, since that is the one the reader
    /// is looking at.
    ///
    /// Taken from the workspaces rather than from the windows: a window registers itself
    /// from `updateNSView`, which SwiftUI runs a turn later, so at launch — exactly when a
    /// file is being opened — the window map is still empty. Going by it meant an open
    /// request found no windows at all and opened one of its own next to the empty one
    /// already sitting there.
    private func orderedWorkspaces() -> [PDFWorkspace] {
        let known = workspaces.allObjects
        // NSApp is nil outside a running application, as in a test, and reaching through it
        // would take the whole process down.
        guard let key = NSApp?.keyWindow, let first = workspacesByWindow.object(forKey: key) else {
            return known
        }
        return [first] + known.filter { $0 !== first }
    }

    /// The window showing `workspace`, once SwiftUI has got round to telling us about it.
    private func window(for workspace: PDFWorkspace) -> NSWindow? {
        (NSApp?.orderedWindows ?? []).first { workspacesByWindow.object(forKey: $0) === workspace }
    }

    /// Queues a file for the next window to open, so a document arriving from the Finder
    /// or a drop lands in its own window instead of replacing what is already on screen.
    func enqueueDocument(_ url: URL) {
        // The same file can be handed to the app twice — the delegate is told about a
        // Finder "Open With" and SwiftUI reports it again — and queueing it twice would
        // leave an entry nothing ever claims.
        let target = url.standardizedFileURL
        guard !pendingDocumentURLs.contains(where: { $0.standardizedFileURL == target }) else { return }
        pendingDocumentURLs.append(url)
    }

    func dequeueDocument() -> URL? {
        pendingDocumentURLs.isEmpty ? nil : pendingDocumentURLs.removeFirst()
    }

    /// Told by the first window, which is where the preferences are to hand.
    func prepare(with preferences: AppPreferences, recoveryStore: TemporaryRecoveryStore = .shared) {
        guard self.preferences == nil else { return }
        self.preferences = preferences
        self.recoveryStore = recoveryStore
    }

    /// AppKit has finished launching the app, so what it was launched for is now known.
    ///
    /// Nothing can be known earlier: the window is on screen a tenth of a second before
    /// this, and the file a reader double-clicked arrives in between. Waiting until here
    /// costs nothing a reader can see and is the difference between reopening last
    /// session's documents and not.
    func applicationDidFinishLaunching() {
        // A turn later, so anything already queued for this one — the file being opened —
        // has landed first.
        DispatchQueue.main.async { [weak self] in self?.finishLaunching() }
    }

    func finishLaunching() {
        guard isLaunching else { return }
        isLaunching = false
        guard let preferences else { return }
        // A file was asked for by name, so that is what the reader wants open, and last
        // session's documents stay shut. Work that was never saved is a different matter
        // and comes back either way.
        prepareRestoreQueue(
            preferences: preferences,
            recoveryStore: recoveryStore,
            includingLastSession: !openedDuringLaunch
        )
        handOutRestores()
    }

    /// Gives each queued document to a window with nothing in it, and asks for more windows
    /// when they run out.
    private func handOutRestores() {
        for workspace in orderedWorkspaces() where !workspace.hasDocument {
            guard let item = nextRestoreItem() else { return }
            workspace.restore(item)
        }
        openWindowsForRemainingRestores { requestWindow() }
    }

    /// Whether a window with nothing open in it should offer the welcome screen.
    ///
    /// Empty and waiting is not the same as empty and done. While the app is starting, or
    /// while a file is on its way into a window, or while documents are still reopening,
    /// a window shows nothing rather than an invitation that is about to be replaced.
    /// Once none of that is true, an empty window has nothing better to offer — including
    /// a tab the reader has just opened for the purpose.
    var shouldOfferWelcome: Bool {
        !isLaunching && pendingDocumentURLs.isEmpty && restoreQueue.isEmpty
    }

    var hasPendingDocuments: Bool { !pendingDocumentURLs.isEmpty }

    func shouldRestoreInitialWindow() -> Bool {
        guard !didAssignInitialRestoration else { return false }
        didAssignInitialRestoration = true
        return true
    }

    /// Works out everything the app should reopen: unsaved work waiting in the recovery
    /// store first, then the documents that were on screen when it last quit. Runs once.
    func prepareRestoreQueue(
        preferences: AppPreferences,
        recoveryStore: TemporaryRecoveryStore? = nil,
        includingLastSession: Bool = true
    ) {
        guard shouldRestoreInitialWindow() else { return }
        let store = recoveryStore ?? .shared
        let recoveries = preferences.temporaryAutosave ? store.pendingRecords() : []
        restoreQueue = Array(repeating: .recovery, count: recoveries.count)
        guard includingLastSession, preferences.restoreLastDocument else { return }
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
    func openWindowsForRemainingRestores(_ openWindow: () -> Void) {
        guard !didOpenRestoreWindows else { return }
        didOpenRestoreWindows = true
        for _ in restoreQueue { openWindow() }
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
        for window in (NSApp?.orderedWindows ?? []).reversed() {
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
