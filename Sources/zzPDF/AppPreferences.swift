import AppKit
import SwiftUI

final class AppPreferences: ObservableObject {
    private enum Key {
        static let restoreLastDocument = "restoreLastDocument"
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
        static let confirmPageDeletion = "confirmPageDeletion"
        static let confirmFlattenedExport = "confirmFlattenedExport"
        static let exportFolderPath = "exportFolderPath"
        static let lastDocumentPath = "lastDocumentPath"
        static let lastPageIndex = "lastPageIndex"
        static let lastZoom = "lastZoom"
        static let lastPageLayout = "lastPageLayout"
    }

    private let defaults: UserDefaults

    @Published var restoreLastDocument: Bool { didSet { defaults.set(restoreLastDocument, forKey: Key.restoreLastDocument) } }
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
    @Published var confirmPageDeletion: Bool { didSet { defaults.set(confirmPageDeletion, forKey: Key.confirmPageDeletion) } }
    @Published var confirmFlattenedExport: Bool { didSet { defaults.set(confirmFlattenedExport, forKey: Key.confirmFlattenedExport) } }
    @Published var exportFolderPath: String { didSet { defaults.set(exportFolderPath, forKey: Key.exportFolderPath) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Key.restoreLastDocument: true,
            Key.defaultPageLayout: PageLayoutMode.continuous.rawValue,
            Key.initialTool: CanvasTool.select.rawValue,
            Key.sidebarVisible: true,
            Key.inspectorVisible: true,
            Key.lineWidth: 2.5,
            Key.textFontSize: 15.0,
            Key.shapeHasFill: false,
            Key.autoFitFormText: true,
            Key.confirmPageDeletion: true,
            Key.confirmFlattenedExport: true,
            Key.exportFolderPath: ""
        ])
        restoreLastDocument = defaults.bool(forKey: Key.restoreLastDocument)
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
        confirmPageDeletion = defaults.bool(forKey: Key.confirmPageDeletion)
        confirmFlattenedExport = defaults.bool(forKey: Key.confirmFlattenedExport)
        exportFolderPath = defaults.string(forKey: Key.exportFolderPath) ?? ""
    }

    var lastDocumentURL: URL? {
        let path = defaults.string(forKey: Key.lastDocumentPath) ?? ""
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
    var lastPageIndex: Int { defaults.integer(forKey: Key.lastPageIndex) }
    var lastZoom: Double { defaults.double(forKey: Key.lastZoom) }
    var lastPageLayout: PageLayoutMode {
        PageLayoutMode(rawValue: defaults.string(forKey: Key.lastPageLayout) ?? "") ?? defaultPageLayout
    }

    func rememberDocument(_ url: URL, pageIndex: Int, zoom: Double, layout: PageLayoutMode) {
        defaults.set(url.path, forKey: Key.lastDocumentPath)
        defaults.set(max(0, pageIndex), forKey: Key.lastPageIndex)
        defaults.set(max(0, zoom), forKey: Key.lastZoom)
        defaults.set(layout.rawValue, forKey: Key.lastPageLayout)
    }

    func rememberView(pageIndex: Int, zoom: Double, layout: PageLayoutMode) {
        defaults.set(max(0, pageIndex), forKey: Key.lastPageIndex)
        if zoom > 0 { defaults.set(zoom, forKey: Key.lastZoom) }
        defaults.set(layout.rawValue, forKey: Key.lastPageLayout)
    }

    func forgetLastDocument() {
        defaults.removeObject(forKey: Key.lastDocumentPath)
        defaults.removeObject(forKey: Key.lastPageIndex)
        defaults.removeObject(forKey: Key.lastZoom)
        defaults.removeObject(forKey: Key.lastPageLayout)
    }

    func reset() {
        restoreLastDocument = true
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
        confirmPageDeletion = true
        confirmFlattenedExport = true
        exportFolderPath = ""
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
