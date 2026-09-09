import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        TabView {
            generalSettings
                .tabItem { Label("General", systemImage: "gearshape") }
            editingSettings
                .tabItem { Label("Editing", systemImage: "pencil.and.outline") }
            exportSettings
                .tabItem { Label("Export", systemImage: "square.and.arrow.up") }
        }
        .frame(width: 520, height: 390)
        .padding(20)
    }

    private var generalSettings: some View {
        Form {
            Section("Startup") {
                Toggle("Restore the previously open PDF", isOn: $preferences.restoreLastDocument)
                Picker("Initial tool", selection: $preferences.initialTool) {
                    Label("Select", systemImage: CanvasTool.select.symbol).tag(CanvasTool.select)
                    Label("Fill Forms", systemImage: CanvasTool.fillForms.symbol).tag(CanvasTool.fillForms)
                }
            }
            Section("Workspace") {
                Picker("Default page layout", selection: $preferences.defaultPageLayout) {
                    ForEach(PageLayoutMode.allCases) { layout in
                        Label(layout.label, systemImage: layout.symbol).tag(layout)
                    }
                }
                .onChange(of: preferences.defaultPageLayout) { _, layout in workspace.setPageLayout(layout) }
                Toggle("Show thumbnails", isOn: $workspace.sidebarVisible)
                Toggle("Show Inspector", isOn: $workspace.inspectorVisible)
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    preferences.reset()
                    workspace.applyDefaultPreferences()
                }
            }
        }
        .formStyle(.grouped)
    }

    private var editingSettings: some View {
        Form {
            Section("Annotations") {
                HStack {
                    Text("Default color")
                    Spacer()
                    ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: true).labelsHidden()
                }
                LabeledContent("Default stroke width") {
                    HStack {
                        Slider(value: $workspace.lineWidth, in: 0.5...12, step: 0.5).frame(width: 190)
                        Text(String(format: "%.1f pt", workspace.lineWidth)).monospacedDigit().frame(width: 52)
                    }
                }
                LabeledContent("Default text size") {
                    HStack {
                        Slider(value: $workspace.textFontSize, in: 8...72, step: 1).frame(width: 190)
                        Text("\(Int(workspace.textFontSize)) pt").monospacedDigit().frame(width: 52)
                    }
                }
                Toggle("Fill new shapes", isOn: $workspace.shapeHasFill)
                if workspace.shapeHasFill {
                    HStack {
                        Text("Default shape fill")
                        Spacer()
                        ColorPicker("", selection: $workspace.shapeFillColor, supportsOpacity: true).labelsHidden()
                    }
                }
            }
            Section("Forms") {
                Toggle("Automatically shrink text to fit form fields", isOn: $preferences.autoFitFormText)
                    .onChange(of: preferences.autoFitFormText) { _, _ in workspace.refreshPreferenceAppearance() }
            }
        }
        .formStyle(.grouped)
    }

    private var exportSettings: some View {
        Form {
            Section("Default Location") {
                LabeledContent("Folder") {
                    Text(preferences.exportFolderPath.isEmpty ? "Ask every time" : URL(fileURLWithPath: preferences.exportFolderPath).lastPathComponent)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                HStack {
                    Button("Choose Folder…") { chooseExportFolder() }
                    if !preferences.exportFolderPath.isEmpty {
                        Button("Clear") { preferences.exportFolderPath = "" }
                    }
                }
            }
            Section("Confirmations") {
                Toggle("Confirm before deleting a page", isOn: $preferences.confirmPageDeletion)
                Toggle("Confirm before exporting a flattened copy", isOn: $preferences.confirmFlattenedExport)
            }
            Text("Flattening permanently applies annotations and redactions to the exported copy.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if !preferences.exportFolderPath.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: preferences.exportFolderPath)
        }
        if panel.runModal() == .OK, let url = panel.url {
            preferences.exportFolderPath = url.path
        }
    }
}
