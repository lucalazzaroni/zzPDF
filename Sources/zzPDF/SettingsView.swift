import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var preferences: AppPreferences
    @EnvironmentObject private var registry: WorkspaceRegistry

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
                Toggle("Keep temporary recovery copies", isOn: $preferences.temporaryAutosave)
                    .onChange(of: preferences.temporaryAutosave) { _, _ in applyPreferences() }
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
                .onChange(of: preferences.defaultPageLayout) { _, _ in applyPreferences() }
                Toggle("Show thumbnails", isOn: $preferences.sidebarVisible)
                    .onChange(of: preferences.sidebarVisible) { _, _ in applyPreferences() }
                Toggle("Show Inspector", isOn: $preferences.inspectorVisible)
                    .onChange(of: preferences.inspectorVisible) { _, _ in applyPreferences() }
            }
            HStack {
                Spacer()
                Button("Restore Defaults") {
                    preferences.reset()
                    applyPreferences()
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
                    ColorPicker("", selection: $preferences.annotationColor, supportsOpacity: true)
                        .labelsHidden()
                        .onChange(of: preferences.annotationColor) { _, _ in applyPreferences() }
                }
                LabeledContent("Default stroke width") {
                    HStack {
                        Slider(value: $preferences.lineWidth, in: 0.5...12, step: 0.5)
                            .frame(width: 190)
                            .onChange(of: preferences.lineWidth) { _, _ in applyPreferences() }
                        Text(String(format: "%.1f pt", preferences.lineWidth)).monospacedDigit().frame(width: 52)
                    }
                }
                LabeledContent("Default text size") {
                    HStack {
                        Slider(value: $preferences.textFontSize, in: 8...72, step: 1)
                            .frame(width: 190)
                            .onChange(of: preferences.textFontSize) { _, _ in applyPreferences() }
                        Text("\(Int(preferences.textFontSize)) pt").monospacedDigit().frame(width: 52)
                    }
                }
                Toggle("Fill new shapes", isOn: $preferences.shapeHasFill)
                    .onChange(of: preferences.shapeHasFill) { _, _ in applyPreferences() }
                if preferences.shapeHasFill {
                    HStack {
                        Text("Default shape fill")
                        Spacer()
                        ColorPicker("", selection: $preferences.shapeFillColor, supportsOpacity: true)
                            .labelsHidden()
                            .onChange(of: preferences.shapeFillColor) { _, _ in applyPreferences() }
                    }
                }
            }
            Section("Markup") {
                LabeledContent("Highlight strength") {
                    HStack {
                        Slider(value: $preferences.highlightOpacity, in: 0.1...1)
                            .frame(width: 190)
                        Text("\(Int(preferences.highlightOpacity * 100))%").monospacedDigit().frame(width: 52)
                    }
                }
            }
            Section("Forms") {
                Toggle("Automatically shrink text to fit form fields", isOn: $preferences.autoFitFormText)
                    .onChange(of: preferences.autoFitFormText) { _, _ in applyPreferences() }
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

    private func applyPreferences() {
        registry.applyPreferencesToOpenDocuments()
    }
}
