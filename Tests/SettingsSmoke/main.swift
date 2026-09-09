import AppKit
import SwiftUI

@main
struct SettingsSmoke {
    @MainActor
    static func main() {
        let suiteName = "it.lucalazzaroni.zzpdf.tests.settings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: defaults)
        guard preferences.restoreLastDocument,
              preferences.temporaryAutosave,
              preferences.defaultPageLayout == .continuous,
              preferences.initialTool == .select,
              preferences.autoFitFormText else {
            fatalError("Default settings are incorrect.")
        }

        let workspace = PDFWorkspace(preferences: preferences)
        workspace.lineWidth = 6.5
        workspace.textFontSize = 24
        workspace.sidebarVisible = false
        workspace.inspectorVisible = false
        workspace.shapeHasFill = true
        workspace.annotationColor = Color(.sRGB, red: 0.2, green: 0.4, blue: 0.6)
        workspace.shapeFillColor = Color(.sRGB, red: 0.7, green: 0.3, blue: 0.1)
        preferences.initialTool = .fillForms
        preferences.confirmPageDeletion = false
        preferences.exportFolderPath = "/tmp/zzPDF Exports"

        let reloaded = AppPreferences(defaults: defaults)
        guard abs(reloaded.lineWidth - 6.5) < 0.01,
              abs(reloaded.textFontSize - 24) < 0.01,
              !reloaded.sidebarVisible,
              !reloaded.inspectorVisible,
              reloaded.shapeHasFill,
              colorsMatch(reloaded.annotationColor, workspace.annotationColor),
              colorsMatch(reloaded.shapeFillColor, workspace.shapeFillColor),
              reloaded.initialTool == .fillForms,
              !reloaded.confirmPageDeletion,
              reloaded.exportFolderPath == "/tmp/zzPDF Exports" else {
            fatalError("Settings were not persisted.")
        }

        reloaded.reset()
        guard reloaded.sidebarVisible,
              reloaded.inspectorVisible,
              reloaded.temporaryAutosave,
              reloaded.initialTool == .select,
              abs(reloaded.lineWidth - 2.5) < 0.01,
              abs(reloaded.textFontSize - 15) < 0.01,
              reloaded.exportFolderPath.isEmpty else {
            fatalError("Settings were not restored to their defaults.")
        }

        print("Settings persistence smoke test passed.")
    }

    private static func colorsMatch(_ lhs: Color, _ rhs: Color) -> Bool {
        guard let left = NSColor(lhs).usingColorSpace(.deviceRGB),
              let right = NSColor(rhs).usingColorSpace(.deviceRGB) else { return false }
        return abs(left.redComponent - right.redComponent) < 0.001
            && abs(left.greenComponent - right.greenComponent) < 0.001
            && abs(left.blueComponent - right.blueComponent) < 0.001
            && abs(left.alphaComponent - right.alphaComponent) < 0.001
    }
}
