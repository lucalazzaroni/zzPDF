import AppKit
import CoreImage
import SwiftUI

final class AppPreferences: ObservableObject {
    private enum Key {
        static let restoreLastDocument = "restoreLastDocument"
        static let temporaryAutosave = "temporaryAutosave"
        static let defaultPageLayout = "defaultPageLayout"
        static let initialTool = "initialTool"
        static let sidebarVisible = "sidebarVisible"
        static let inspectorVisible = "inspectorVisible"
        static let toolColors = "toolColors"
        static let lineWidth = "lineWidth"
        static let textFontSize = "textFontSize"
        static let shapeHasFill = "shapeHasFill"
        static let shapeFillColor = "shapeFillColor"
        static let autoFitFormText = "autoFitFormText"
        static let highlightOpacity = "highlightOpacity"
        static let annotationAuthor = "annotationAuthor"
        static let readingMode = "readingMode"
        static let confirmPageDeletion = "confirmPageDeletion"
        static let confirmFlattenedExport = "confirmFlattenedExport"
        static let exportFolderPath = "exportFolderPath"
        static let signatureStrokes = "signatureStrokes"
        static let signatureImage = "signatureImage"
        static let sessionDocuments = "sessionDocuments"
        static let recentDocuments = "recentDocuments"
        static let personalProfile = "personalProfile"
    }

    private let defaults: UserDefaults

    @Published var restoreLastDocument: Bool { didSet { defaults.set(restoreLastDocument, forKey: Key.restoreLastDocument) } }
    @Published var temporaryAutosave: Bool { didSet { defaults.set(temporaryAutosave, forKey: Key.temporaryAutosave) } }
    @Published var defaultPageLayout: PageLayoutMode { didSet { defaults.set(defaultPageLayout.rawValue, forKey: Key.defaultPageLayout) } }
    @Published var initialTool: CanvasTool { didSet { defaults.set(initialTool.rawValue, forKey: Key.initialTool) } }
    @Published var sidebarVisible: Bool { didSet { defaults.set(sidebarVisible, forKey: Key.sidebarVisible) } }
    @Published var inspectorVisible: Bool { didSet { defaults.set(inspectorVisible, forKey: Key.inspectorVisible) } }
    /// Each tool's own colour, kept by the tool's name. A tool not in here uses its default.
    @Published private(set) var toolColors: [String: Color] { didSet { saveToolColors() } }
    @Published var lineWidth: Double { didSet { defaults.set(lineWidth, forKey: Key.lineWidth) } }
    @Published var textFontSize: Double { didSet { defaults.set(textFontSize, forKey: Key.textFontSize) } }
    @Published var shapeHasFill: Bool { didSet { defaults.set(shapeHasFill, forKey: Key.shapeHasFill) } }
    @Published var shapeFillColor: Color { didSet { saveColor(shapeFillColor, key: Key.shapeFillColor) } }
    @Published var autoFitFormText: Bool { didSet { defaults.set(autoFitFormText, forKey: Key.autoFitFormText) } }
    @Published var highlightOpacity: Double { didSet { defaults.set(highlightOpacity, forKey: Key.highlightOpacity) } }
    @Published var annotationAuthor: String { didSet { defaults.set(annotationAuthor, forKey: Key.annotationAuthor) } }
    @Published var readingMode: ReadingMode { didSet { defaults.set(readingMode.rawValue, forKey: Key.readingMode) } }
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
            Key.readingMode: ReadingMode.normal.rawValue,
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
        toolColors = Self.loadToolColors(defaults: defaults)
        lineWidth = max(0.5, min(defaults.double(forKey: Key.lineWidth), 12))
        textFontSize = max(8, min(defaults.double(forKey: Key.textFontSize), 72))
        shapeHasFill = defaults.bool(forKey: Key.shapeHasFill)
        shapeFillColor = Self.loadColor(defaults: defaults, key: Key.shapeFillColor) ?? .black
        autoFitFormText = defaults.bool(forKey: Key.autoFitFormText)
        highlightOpacity = max(0.05, min(defaults.double(forKey: Key.highlightOpacity), 1))
        annotationAuthor = defaults.string(forKey: Key.annotationAuthor) ?? NSFullUserName()
        readingMode = ReadingMode(rawValue: defaults.string(forKey: Key.readingMode) ?? "") ?? .normal
        confirmPageDeletion = defaults.bool(forKey: Key.confirmPageDeletion)
        confirmFlattenedExport = defaults.bool(forKey: Key.confirmFlattenedExport)
        exportFolderPath = defaults.string(forKey: Key.exportFolderPath) ?? ""
        if let data = defaults.data(forKey: Key.personalProfile),
           let stored = try? JSONDecoder().decode(PersonalProfile.self, from: data) {
            personalProfile = stored
        }
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
    /// The reader's own details, for filling in forms.
    @Published var personalProfile: PersonalProfile = PersonalProfile() {
        didSet {
            guard let data = try? JSONEncoder().encode(personalProfile) else { return }
            defaults.set(data, forKey: Key.personalProfile)
        }
    }

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
        toolColors = [:]
        lineWidth = 2.5
        textFontSize = 15
        shapeHasFill = false
        shapeFillColor = .black
        autoFitFormText = true
        highlightOpacity = 0.45
        annotationAuthor = NSFullUserName()
        readingMode = .normal
        confirmPageDeletion = true
        confirmFlattenedExport = true
        exportFolderPath = ""
        signatureStrokes = []
        signatureImageData = nil
        clearRecentDocuments()
        forgetAllDocuments()
    }

    // MARK: - Colours, one per tool

    /// What each tool draws in when the reader has not chosen otherwise.
    ///
    /// One colour used to be shared by every tool, so choosing black for text made the next
    /// highlight black too — which blotted out what it was meant to mark. Each tool now
    /// keeps its own, and changing one leaves the others alone.
    static let defaultToolColors: [CanvasTool: Color] = [
        .highlight: HighlightPalette.yellow,
        .underline: Color(.sRGB, red: 0.13, green: 0.45, blue: 0.95),
        .strikeOut: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .text: .black,
        .draw: Color(.sRGB, red: 0.13, green: 0.45, blue: 0.95),
        .line: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .arrow: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .polygon: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .rectangle: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .oval: Color(.sRGB, red: 0.86, green: 0.16, blue: 0.16),
        .signature: .black
    ]

    func color(for tool: CanvasTool) -> Color {
        toolColors[tool.rawValue] ?? Self.defaultToolColors[tool] ?? .black
    }

    func setColor(_ color: Color, for tool: CanvasTool) {
        toolColors[tool.rawValue] = color
    }

    func resetToolColors() {
        toolColors = [:]
    }

    private func saveToolColors() {
        var stored: [String: [Double]] = [:]
        for (tool, color) in toolColors {
            guard let rgb = NSColor(color).usingColorSpace(.deviceRGB) else { continue }
            stored[tool] = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        }
        defaults.set(stored, forKey: Key.toolColors)
    }

    private static func loadToolColors(defaults: UserDefaults) -> [String: Color] {
        guard let stored = defaults.dictionary(forKey: Key.toolColors) as? [String: [Double]] else { return [:] }
        return stored.reduce(into: [:]) { colors, entry in
            let c = entry.value
            guard c.count == 4 else { return }
            colors[entry.key] = Color(.sRGB, red: c[0], green: c[1], blue: c[2], opacity: c[3])
        }
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

/// How pages are tinted on screen. This changes nothing in the document: it is a Core
/// Animation filter over the view, for reading in the dark or on a warm background.
enum ReadingMode: String, CaseIterable, Identifiable {
    case normal, night, sepia

    var id: String { rawValue }

    var label: String {
        switch self {
        case .normal: "Normal"
        case .night: "Night"
        case .sepia: "Sepia"
        }
    }

    var symbol: String {
        switch self {
        case .normal: "sun.max"
        case .night: "moon"
        case .sepia: "book.closed"
        }
    }

    /// The filters the page view is composited through.
    var filters: [CIFilter] {
        switch self {
        case .normal:
            return []
        case .night:
            return [CIFilter(name: "CIColorInvert")].compactMap { $0 }
        case .sepia:
            let sepia = CIFilter(name: "CISepiaTone")
            sepia?.setValue(0.55, forKey: kCIInputIntensityKey)
            return [sepia].compactMap { $0 }
        }
    }

    /// Night mode inverts everything the view draws, so the surround has to start white
    /// to end up dark.
    var backgroundColor: NSColor {
        switch self {
        case .normal: NSColor(calibratedWhite: 0.13, alpha: 1)
        case .night: NSColor(calibratedWhite: 0.87, alpha: 1)
        case .sepia: NSColor(calibratedWhite: 0.30, alpha: 1)
        }
    }
}


/// The colours a highlight can be. A highlighter is a highlighter: a few clear, light
/// colours that leave the text under them readable, not the whole of the colour wheel —
/// which is how a highlight came out black.
enum HighlightPalette {
    static let yellow = Color(.sRGB, red: 1.0, green: 0.84, blue: 0.04)
    static let green = Color(.sRGB, red: 0.40, green: 0.85, blue: 0.35)
    static let blue = Color(.sRGB, red: 0.35, green: 0.70, blue: 1.0)
    static let pink = Color(.sRGB, red: 1.0, green: 0.45, blue: 0.70)
    static let orange = Color(.sRGB, red: 1.0, green: 0.62, blue: 0.20)
    static let purple = Color(.sRGB, red: 0.72, green: 0.50, blue: 1.0)

    static let all: [(name: String, color: Color)] = [
        ("Yellow", yellow), ("Green", green), ("Blue", blue),
        ("Pink", pink), ("Orange", orange), ("Purple", purple)
    ]

    /// The palette colour nearest to `color`, for showing which one an existing highlight
    /// is — including one made before the palette, in any colour at all.
    static func nearest(to color: NSColor) -> Color {
        guard let target = color.usingColorSpace(.sRGB) else { return yellow }
        return all.min { a, b in
            distance(NSColor(a.color), target) < distance(NSColor(b.color), target)
        }?.color ?? yellow
    }

    private static func distance(_ a: NSColor, _ b: NSColor) -> CGFloat {
        guard let a = a.usingColorSpace(.sRGB) else { return .greatestFiniteMagnitude }
        let dr = a.redComponent - b.redComponent, dg = a.greenComponent - b.greenComponent
        let db = a.blueComponent - b.blueComponent
        return dr * dr + dg * dg + db * db
    }
}
