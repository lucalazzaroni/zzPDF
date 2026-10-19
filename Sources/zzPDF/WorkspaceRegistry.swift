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
    /// The windows in the order they appeared, so the newest can be found again.
    private var arrivals: [WeakWorkspace] = []
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
    /// A window has been asked for and has not arrived yet.
    private var windowRequestInFlight = false
    @Published private var restoreQueue: [RestoreItem] = []
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
    /// The same, reached through the menu commands, which exist before any window does.
    ///
    /// A launch to open a file shows no window of its own: the scene is told to leave
    /// external events alone, so SwiftUI does not create one for the event, and it does not
    /// create the usual first window either. The file then waited for a window to ask for
    /// it, and the only thing able to ask for a window was a window — so double-clicking a
    /// PDF with nothing to reopen started the app and showed nothing at all.
    private var commandWindowOpener: (() -> Void)?
    private var windowOpener: (() -> Void)? { requestNewWindow ?? commandWindowOpener }
    /// The document the reader asked for while the app was starting.
    private weak var requestedDocument: PDFWorkspace?
    /// Set when the launch finished before anything had told the registry its preferences.
    private var restoreWhenPrepared = false
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
        arrivals.removeAll { $0.value == nil }
        guard !arrivals.contains(where: { $0.value === workspace }) else { return }
        arrivals.append(WeakWorkspace(workspace))
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
        windowOpener?()
    }

    /// Connects the registry to what the menu commands can reach, which is available from
    /// the moment the app starts rather than from the moment a window first appears.
    func attach(preferences: AppPreferences, openWindow: @escaping () -> Void) {
        commandWindowOpener = openWindow
        prepare(with: preferences)
    }

    /// Notes that `workspace` holds the file the reader asked for, so that documents
    /// reopening from last time take their tabs without taking the front from it.
    func noteRequestedDocument(in workspace: PDFWorkspace) {
        requestedDocument = workspace
    }

    private func bringRequestedDocumentForward() {
        guard let target = requestedDocument, let window = window(for: target) else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
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
            // A document reopening from last time joins quietly. Every new tab used to take
            // the front as it arrived, and these arrive after the file the reader
            // double-clicked, so one of last session's documents ended up in front of it.
            if workspace.wasReopened, let target = requestedDocument, target !== workspace {
                bringRequestedDocumentForward()
                return
            }
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
        let target = sameFile(url)
        if let index = candidates.firstIndex(where: { $0.url.map(sameFile) == target }) {
            return .front(index)
        }
        if let index = candidates.firstIndex(where: \.isEmpty) {
            return .loadInto(index)
        }
        return .newWindow
    }

    /// Opens a document that arrived from the Finder, a drop, or the recent-documents menu.
    ///
    /// AppKit delivers Finder requests here once. Recent documents and drops use the same
    /// route, so SwiftUI never creates a second, empty window for the same open event.
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
            noteRequestedDocument(in: candidates[index])
            window(for: candidates[index])?.makeKeyAndOrderFront(nil)
        case .newWindow:
            enqueueDocument(url)
            requestWindowForWaitingWork()
        }
    }

    /// The window already showing `url`, if any.
    func window(showing url: URL) -> NSWindow? {
        let target = sameFile(url)
        guard let workspace = workspaces.allObjects.first(where: {
            $0.fileURL.map(sameFile) == target
        }) else { return nil }
        return window(for: workspace)
    }

    /// Every workspace on screen, the one that appeared most recently first.
    ///
    /// Prefer the newest empty tab. Use workspace registration rather than the window map:
    /// SwiftUI configures the native window a turn later, and a launch-time file may arrive
    /// before that map has any entries.
    private func orderedWorkspaces() -> [PDFWorkspace] {
        arrivals.compactMap(\.value).reversed()
    }

    /// The window showing `workspace`, once SwiftUI has got round to telling us about it.
    private func window(for workspace: PDFWorkspace) -> NSWindow? {
        configuredWindows.allObjects.first { workspacesByWindow.object(forKey: $0) === workspace }
    }

    func windowDidClose(_ window: NSWindow) {
        if let workspace = workspacesByWindow.object(forKey: window) {
            workspaces.remove(workspace)
            arrivals.removeAll { $0.value == nil || $0.value === workspace }
        }
        workspacesByWindow.removeObject(forKey: window)
        configuredWindows.remove(window)
        delegateProxies.removeObject(forKey: window)
    }

    /// Queues a file for the next window to open, so a document arriving from the Finder
    /// or a drop lands in its own window instead of replacing what is already on screen.
    func enqueueDocument(_ url: URL) {
        // The same file can be handed to the app twice — the delegate is told about a
        // Finder "Open With" and SwiftUI reports it again — and queueing it twice would
        // leave an entry nothing ever claims.
        let target = sameFile(url)
        guard !pendingDocumentURLs.contains(where: { sameFile($0) == target }) else { return }
        pendingDocumentURLs.append(url)
    }

    /// Called by every window as it appears, and answered with the file waiting for it if
    /// there is one. Its arrival is also the moment to ask for the next window, once it has
    /// taken what it came for.
    func dequeueDocument() -> URL? {
        windowRequestInFlight = false
        DispatchQueue.main.async { [weak self] in self?.requestWindowForWaitingWork() }
        return pendingDocumentURLs.isEmpty ? nil : pendingDocumentURLs.removeFirst()
    }

    /// Asks for one more window while anything is still waiting for one: a file, or a
    /// document reopening from last time.
    ///
    /// One at a time, and only once the last has arrived and taken its share. Counting in
    /// advance does not work: a window asked for on behalf of a reopening document takes
    /// a waiting file first, because the file is what the reader asked for, and the count
    /// then came up one window short — leaving unsaved work queued with nowhere to show.
    private func requestWindowForWaitingWork() {
        // During launch SwiftUI may still supply a window of its own, and nothing is
        // decided until the launch is over.
        guard !isLaunching, hasPendingDocuments || !restoreQueue.isEmpty,
              !windowRequestInFlight, let windowOpener else { return }
        windowRequestInFlight = true
        windowOpener()
    }

    /// Told by the first window, which is where the preferences are to hand.
    func prepare(with preferences: AppPreferences, recoveryStore: TemporaryRecoveryStore? = nil) {
        guard self.preferences == nil else { return }
        self.preferences = preferences
        self.recoveryStore = recoveryStore ?? .shared
        guard restoreWhenPrepared else { return }
        restoreWhenPrepared = false
        // A turn later, so the window that brought the preferences has taken the file
        // meant for it before anything reopening is handed out.
        DispatchQueue.main.async { [weak self] in self?.reopenAfterLaunch() }
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
        if preferences == nil {
            restoreWhenPrepared = true
        } else {
            reopenAfterLaunch()
        }
        requestWindowForWaitingWork()
    }

    private func reopenAfterLaunch() {
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
            guard let item = nextRestoreItem() else { break }
            workspace.restore(item)
        }
        requestWindowForWaitingWork()
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
        let recovered = Set(recoveries.compactMap(\.originalPath).map { sameFile(URL(fileURLWithPath: $0)) })
        for document in preferences.sessionDocuments
        where !recovered.contains(sameFile(document.url)) && FileManager.default.fileExists(atPath: document.path) {
            restoreQueue.append(.session(document))
        }
    }

    func nextRestoreItem() -> RestoreItem? {
        restoreQueue.isEmpty ? nil : restoreQueue.removeFirst()
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

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            registry?.windowDidClose(window)
        }
        originalDelegate?.windowWillClose?(notification)
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



/// What a file is, for deciding whether two references are to the same one.
///
/// Symbolic links resolved, not just dots and double dots tidied away. The same document
/// was recorded once under a path through a link and once under the path it leads to —
/// /tmp and /private/tmp, say — and compared as two different files, so a document that
/// had unsaved work and had also been open last session came back twice.
func sameFile(_ url: URL) -> String {
    url.resolvingSymlinksInPath().standardizedFileURL.path
}

/// Holds a window's workspace without keeping it alive.
private final class WeakWorkspace {
    weak var value: PDFWorkspace?
    init(_ value: PDFWorkspace) { self.value = value }
}
