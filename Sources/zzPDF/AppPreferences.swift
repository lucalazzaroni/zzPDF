import AppKit
import SwiftUI

final class AppPreferences: ObservableObject {
    private enum Key {
        static let restoreLastDocument = "restoreLastDocument"
        static let temporaryAutosave = "temporaryAutosave"
        static let defaultPageLayout = "defaultPageLayout"
        static let initialTool = "initialTool"
        static let sidebarVisible = "sidebarVisible"
        static let inspectorVisible = "inspectorVisible"
        static let annotationColor = "annotationColor"
        static let lineWidth = "lineWidth"
        static let textFontSize = "textFontSize"
        static let shapeHasFill = "shapeHasFill"
        static let shapeFillColor = "shapeFillColor"
        static let autoFitFormText = "autoFitFormText"
        static let highlightOpacity = "highlightOpacity"
        static let annotationAuthor = "annotationAuthor"
        static let confirmPageDeletion = "confirmPageDeletion"
        static let confirmFlattenedExport = "confirmFlattenedExport"
        static let exportFolderPath = "exportFolderPath"
        static let signatureStrokes = "signatureStrokes"
        static let signatureImage = "signatureImage"
        static let sessionDocuments = "sessionDocuments"
        static let recentDocuments = "recentDocuments"
    }

    private let defaults: UserDefaults

    @Published var restoreLastDocument: Bool { didSet { defaults.set(restoreLastDocument, forKey: Key.restoreLastDocument) } }
    @Published var temporaryAutosave: Bool { didSet { defaults.set(temporaryAutosave, forKey: Key.temporaryAutosave) } }
    @Published var defaultPageLayout: PageLayoutMode { didSet { defaults.set(defaultPageLayout.rawValue, forKey: Key.defaultPageLayout) } }
    @Published var initialTool: CanvasTool { didSet { defaults.set(initialTool.rawValue, forKey: Key.initialTool) } }
    @Published var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: Key.sidebarVisible) } }
    @Published var inspectorVisible: Bool { didSet { defaults.set(inspectorVisible, forKey: Key.inspectorVisible) } }
    @Published var annotationColor: Color { didSet { saveColor(annotationColor, key: Key.annotationColor) } }
    @Published var lineWidth: Double { didSet { defaults.set(lineWidth, forKey: Key.lineWidth) } }
    @Published var textFontSize: Double { didSet { defaults.set(textFontSize, forKey: Key.textFontSize) } }
    @Published var shapeHasFill: Bool { didSet { defaults.set(shapeHasFill, forKey: Key.shapeHasFill) } }
    @Published var shapeFillColor: Color { didSet { saveColor(shapeFillColor, key: Key.shapeFillColor) } }
    @Published var autoFitFormText: Bool { didSet { defaults.set(autoFitFormText, forKey: Key.autoFitFormText) } }
    @Published var highlightOpacity: Double { didSet { defaults.set(highlightOpacity, forKey: Key.highlightOpacity) } }
    @Published var annotationAuthor: String { didSet { defaults.set(annotationAuthor, forKey: Key.annotationAuthor) } }
    @Published var confirmPageDeletion: Bool { didSet { defaults.set(confirmPageDeletion, forKey: Key.confirmPageDeletion) } }
    @Published var confirmFlattenedExport: Bool { didSet { defaults.set(confirmFlattenedExport, forKey: Key.confirmFlattenedExport) } }
    @Published var exportFolderPath: String { didSet { defaults.set(exportFolderPath, forKey: Key.exportFolderPath) } }
    /// Bumped whenever the recent-documents list changes, so the menu rebuilds.
    @Published var recentDocumentsToken = UUID()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.restoreLastDocument: true,
            Key.temporaryAutosave: true,
            Key.defaultPageLayout: PageLayoutMode.continuous.rawValue,
            Key.initialTool: CanvasTool.select.rawValue,
            Key.sidebarVisible: true,
            Key.inspectorVisible: true,
            Key.lineWidth: 2.5,
            Key.textFontSize: 15.0,
            Key.shapeHasFill: false,
            Key.autoFitFormText: true,
            Key.highlightOpacity: 0.45,
            Key.annotationAuthor: NSFullUserName(),
            Key.confirmPageDeletion: true,
            Key.confirmFlattenedExport: true,
            Key.exportFolderPath: ""
        ])
        restoreLastDocument = defaults.bool(forKey: Key.restoreLastDocument)
        temporaryAutosave = defaults.bool(forKey: Key.temporaryAutosave)
        defaultPageLayout = PageLayoutMode(rawValue: defaults.string(forKey: Key.defaultPageLayout) ?? "") ?? .continuous
        let storedTool = CanvasTool(rawValue: defaults.string(forKey: Key.initialTool) ?? "") ?? .select
        initialTool = [.select, .fillForms].contains(storedTool) ? storedTool : .select
        sidebarVisible = defaults.bool(forKey: Key.sidebarVisible)
        inspectorVisible = defaults.bool(forKey: Key.inspectorVisible)
        annotationColor = Self.loadColor(defaults: defaults, key: Key.annotationColor) ?? .black
        lineWidth = max(0.5, min(defaults.double(forKey: Key.lineWidth), 12))
        textFontSize = max(8, min(defaults.double(forKey: Key.textFontSize), 72))
        shapeHasFill = defaults.bool(forKey: Key.shapeHasFill)
        shapeFillColor = Self.loadColor(defaults: defaults, key: Key.shapeFillColor) ?? .black
        autoFitFormText = defaults.bool(forKey: Key.autoFitFormText)
        highlightOpacity = max(0.05, min(defaults.double(forKey: Key.highlightOpacity), 1))
        annotationAuthor = defaults.string(forKey: Key.annotationAuthor) ?? NSFullUserName()
        confirmPageDeletion = defaults.bool(forKey: Key.confirmPageDeletion)
        confirmFlattenedExport = defaults.bool(forKey: Key.confirmFlattenedExport)
        exportFolderPath = defaults.string(forKey: Key.exportFolderPath) ?? ""
    }

    /// A drawn signature, stored as one array of interleaved x/y coordinates per stroke,
    /// so it survives quitting instead of having to be redrawn every session.
    var signatureStrokes: [[CGPoint]] {
        get {
            guard let stored = defaults.array(forKey: Key.signatureStrokes) as? [[Double]] else { return [] }
            return stored.map { stroke in
                stride(from: 0, to: stroke.count - 1, by: 2).map { CGPoint(x: stroke[$0], y: stroke[$0 + 1]) }
            }
            .filter { $0.count > 1 }
        }
        set {
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: Key.signatureStrokes)
                return
            }
            let encoded = newValue.map { stroke in stroke.flatMap { [Double($0.x), Double($0.y)] } }
            defaults.set(encoded, forKey: Key.signatureStrokes)
        }
    }

    var signatureImageData: Data? {
        get { defaults.data(forKey: Key.signatureImage) }
        set {
            if let newValue {
                defaults.set(newValue, forKey: Key.signatureImage)
            } else {
                defaults.removeObject(forKey: Key.signatureImage)
            }
        }
    }

    /// The recent list is kept here rather than in NSDocumentController, which records
    /// nothing in an app that is not built on NSDocument.
    private static let maximumRecentDocuments = 10

    func noteRecentDocument(_ url: URL) {
        let path = url.standardizedFileURL.path
        var paths = (defaults.array(forKey: Key.recentDocuments) as? [String] ?? []).filter { $0 != path }
        paths.insert(path, at: 0)
        defaults.set(Array(paths.prefix(Self.maximumRecentDocuments)), forKey: Key.recentDocuments)
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
        recentDocumentsToken = UUID()
    }

    func clearRecentDocuments() {
        defaults.removeObject(forKey: Key.recentDocuments)
        NSDocumentController.shared.clearRecentDocuments(nil)
        recentDocumentsToken = UUID()
    }

    /// Recently opened files that are still on disk, newest first.
    var recentDocumentURLs: [URL] {
        let paths = defaults.array(forKey: Key.recentDocuments) as? [String] ?? []
        return paths
            .filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    /// One entry per document that was open when the app last quit, frontmost first.
    struct SessionDocument: Codable, Equatable {
        var path: String
        var pageIndex: Int
        var zoom: Double
        var layout: String

        var url: URL { URL(fileURLWithPath: path) }
        var pageLayout: PageLayoutMode { PageLayoutMode(rawValue: layout) ?? .continuous }
    }

    private static let maximumSessionDocuments = 8

    var sessionDocuments: [SessionDocument] {
        get {
            guard let data = defaults.data(forKey: Key.sessionDocuments),
                  let stored = try? JSONDecoder().decode([SessionDocument].self, from: data) else { return [] }
            return stored
        }
        set {
            guard !newValue.isEmpty else {
                defaults.removeObject(forKey: Key.sessionDocuments)
                return
            }
            let trimmed = Array(newValue.prefix(Self.maximumSessionDocuments))
            guard let data = try? JSONEncoder().encode(trimmed) else { return }
            defaults.set(data, forKey: Key.sessionDocuments)
        }
    }

    var lastDocumentURL: URL? { sessionDocuments.first?.url }
    var lastPageIndex: Int { sessionDocuments.first?.pageIndex ?? 0 }
    var lastZoom: Double { sessionDocuments.first?.zoom ?? 0 }
    var lastPageLayout: PageLayoutMode { sessionDocuments.first?.pageLayout ?? defaultPageLayout }

    /// Moves the document to the front of the list, so the window in front when the app
    /// quits is the one restored first.
    func rememberDocument(_ url: URL, pageIndex: Int, zoom: Double, layout: PageLayoutMode) {
        let entry = SessionDocument(
            path: url.standardizedFileURL.path,
            pageIndex: max(0, pageIndex),
            zoom: max(0, zoom),
            layout: layout.rawValue
        )
        var documents = sessionDocuments.filter { $0.path != entry.path }
        documents.insert(entry, at: 0)
        sessionDocuments = documents
    }

    func forgetDocument(_ url: URL) {
        let path = url.standardizedFileURL.path
        sessionDocuments = sessionDocuments.filter { $0.path != path }
    }

    func forgetLastDocument() {
        sessionDocuments = Array(sessionDocuments.dropFirst())
    }

    func forgetAllDocuments() {
        sessionDocuments = []
    }

    func reset() {
        restoreLastDocument = true
        temporaryAutosave = true
        defaultPageLayout = .continuous
        initialTool = .select
        sidebarVisible = true
        inspectorVisible = true
        annotationColor = .black
        lineWidth = 2.5
        textFontSize = 15
        shapeHasFill = false
        shapeFillColor = .black
        autoFitFormText = true
        highlightOpacity = 0.45
        annotationAuthor = NSFullUserName()
        confirmPageDeletion = true
        confirmFlattenedExport = true
        exportFolderPath = ""
        signatureStrokes = []
        signatureImageData = nil
        clearRecentDocuments()
        forgetAllDocuments()
    }

    private func saveColor(_ color: Color, key: String) {
        guard let converted = NSColor(color).usingColorSpace(.deviceRGB) else { return }
        defaults.set([converted.redComponent, converted.greenComponent, converted.blueComponent, converted.alphaComponent], forKey: key)
    }

    private static func loadColor(defaults: UserDefaults, key: String) -> Color? {
        guard let components = defaults.array(forKey: key) as? [Double], components.count == 4 else { return nil }
        return Color(.sRGB, red: components[0], green: components[1], blue: components[2], opacity: components[3])
    }
}
