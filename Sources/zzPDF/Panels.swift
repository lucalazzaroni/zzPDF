import AppKit
import PDFKit
import SwiftUI

struct PageSidebar: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("PAGINE")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(workspace.pageCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(0..<workspace.pageCount, id: \.self) { index in
                            PageThumbnail(index: index, selected: index == workspace.currentPageIndex)
                                .id(index)
                                .onTapGesture { workspace.selectPage(index) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
                .onChange(of: workspace.currentPageIndex) { _, value in
                    withAnimation { proxy.scrollTo(value, anchor: .center) }
                }
            }

            Divider()
            HStack(spacing: 12) {
                Button { workspace.moveCurrentPage(by: -1) } label: { Image(systemName: "arrow.up") }
                    .help("Sposta prima")
                    .disabled(workspace.currentPageIndex == 0)
                Button { workspace.moveCurrentPage(by: 1) } label: { Image(systemName: "arrow.down") }
                    .help("Sposta dopo")
                    .disabled(workspace.currentPageIndex >= workspace.pageCount - 1)
                Button { workspace.duplicateCurrentPage() } label: { Image(systemName: "plus.square.on.square") }
                    .help("Duplica")
                Spacer()
                Button(role: .destructive) { workspace.deleteCurrentPage() } label: { Image(systemName: "trash") }
                    .help("Elimina")
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 13)
            .frame(height: 38)
        }
        .frame(minWidth: 145, idealWidth: 175, maxWidth: 215)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct PageThumbnail: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    let index: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 5) {
            Group {
                if let page = workspace.pdfDocument?.page(at: index) {
                    Image(nsImage: page.thumbnail(of: CGSize(width: 126, height: 164), for: .cropBox))
                        .resizable()
                        .scaledToFit()
                        .background(.white)
                } else {
                    Rectangle().fill(.white)
                }
            }
            .frame(maxWidth: 126, minHeight: 90, maxHeight: 164)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 3, y: 2)
            Text("\(index + 1)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(selected ? Color.accentColor : .secondary)
        }
        .padding(4)
        .contentShape(Rectangle())
    }
}

struct InspectorPanel: View {
    @EnvironmentObject private var workspace: PDFWorkspace

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                inspectorHeader
                Divider()
                activeToolControls
                Divider()
                markupControls
                Divider()
                pageControls
                Divider()
                documentControls
            }
            .padding(16)
        }
        .frame(minWidth: 245, idealWidth: 270, maxWidth: 310)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var inspectorHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(workspace.displayName)
                .font(.headline)
                .lineLimit(1)
            Text("\(workspace.pageCount) pagine")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var activeToolControls: some View {
        VStack(alignment: .leading, spacing: 11) {
            Label(workspace.activeTool.label, systemImage: workspace.activeTool.symbol)
                .font(.subheadline.weight(.semibold))
            if workspace.activeTool == .text {
                TextField("Testo da inserire", text: $workspace.textToInsert, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            if workspace.activeTool == .note {
                TextField("Contenuto della nota", text: $workspace.noteText, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
            }
            if workspace.activeTool != .select && workspace.activeTool != .redact {
                HStack {
                    Text("Colore").font(.callout)
                    Spacer()
                    ColorPicker("", selection: $workspace.annotationColor, supportsOpacity: true)
                        .labelsHidden()
                }
            }
            if [.draw, .rectangle, .oval, .signature].contains(workspace.activeTool) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Spessore").font(.callout)
                        Spacer()
                        Text(String(format: "%.1f pt", workspace.lineWidth))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $workspace.lineWidth, in: 0.5...12)
                }
            }
            if workspace.activeTool == .signature {
                Button(workspace.savedSignature.isEmpty ? "Crea firma…" : "Modifica firma…") {
                    workspace.showSignaturePad = true
                }
            }
            Text(toolHint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var toolHint: String {
        switch workspace.activeTool {
        case .select: "Seleziona testo o compila direttamente i campi del modulo."
        case .note: "Fai clic sulla pagina per inserire una nota."
        case .text: "Fai clic sulla pagina per inserire il testo."
        case .draw: "Trascina sulla pagina per disegnare a mano libera."
        case .rectangle, .oval: "Trascina per disegnare la forma."
        case .redact: "Trascina sull'area da oscurare, poi esporta una copia appiattita."
        case .signature: "Fai clic nel punto in cui vuoi inserire la firma."
        }
    }

    private var markupControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TESTO SELEZIONATO")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                InspectorIconButton(icon: "highlighter", help: "Evidenzia") { workspace.addMarkup(.highlight) }
                InspectorIconButton(icon: "underline", help: "Sottolinea") { workspace.addMarkup(.underline) }
                InspectorIconButton(icon: "strikethrough", help: "Barra") { workspace.addMarkup(.strikeOut) }
                InspectorIconButton(icon: "trash", help: "Rimuovi annotazione") { workspace.removeSelectedAnnotation() }
            }
        }
    }

    private var pageControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PAGINA")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                InspectorIconButton(icon: "rotate.left", help: "Ruota a sinistra") { workspace.rotateCurrentPage(by: -90) }
                InspectorIconButton(icon: "rotate.right", help: "Ruota a destra") { workspace.rotateCurrentPage(by: 90) }
                InspectorIconButton(icon: "plus.square.on.square", help: "Duplica") { workspace.duplicateCurrentPage() }
                InspectorIconButton(icon: "scissors", help: "Estrai") { workspace.extractCurrentPage() }
            }
            HStack {
                Button("Riduci margini") { workspace.changePageBox(.cropBox, inset: 8) }
                Button("Ripristina") {
                    guard let page = workspace.pdfDocument?.page(at: workspace.currentPageIndex) else { return }
                    page.setBounds(page.bounds(for: .mediaBox), for: .cropBox)
                    workspace.changed("Ritaglio ripristinato")
                }
            }
            .controlSize(.small)
        }
    }

    private var documentControls: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("DOCUMENTO")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Button { workspace.mergePDF() } label: { Label("Unisci PDF…", systemImage: "square.stack.3d.up") }
            Button { workspace.importImages() } label: { Label("Aggiungi immagini…", systemImage: "photo.on.rectangle.angled") }
            Button { workspace.recognizeCurrentPage() } label: { Label("Riconosci testo (OCR)", systemImage: "text.viewfinder") }
            Button { workspace.exportFlattened() } label: { Label("Esporta appiattito…", systemImage: "doc.badge.gearshape") }
            Button { workspace.showPasswordExport = true } label: { Label("Proteggi con password…", systemImage: "lock") }
        }
        .buttonStyle(.plain)
    }
}

struct InspectorIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .frame(width: 31, height: 28)
                .background(.quaternary.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct SignatureSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Binding var strokes: [[CGPoint]]
    @State private var workingStrokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("La tua firma").font(.title2.bold())
                Text("Disegna nel riquadro con il mouse o il trackpad.").foregroundStyle(.secondary)
            }
            GeometryReader { geometry in
                Canvas { context, size in
                    for stroke in workingStrokes + (currentStroke.isEmpty ? [] : [currentStroke]) {
                        guard let first = stroke.first else { continue }
                        var path = Path()
                        path.move(to: CGPoint(x: first.x * size.width, y: first.y * size.height))
                        for point in stroke.dropFirst() {
                            path.addLine(to: CGPoint(x: point.x * size.width, y: point.y * size.height))
                        }
                        context.stroke(path, with: .color(.primary), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary, lineWidth: 1))
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let point = CGPoint(
                                x: min(max(value.location.x / geometry.size.width, 0), 1),
                                y: min(max(value.location.y / geometry.size.height, 0), 1)
                            )
                            currentStroke.append(point)
                        }
                        .onEnded { _ in
                            if currentStroke.count > 1 { workingStrokes.append(currentStroke) }
                            currentStroke = []
                        }
                )
            }
            .frame(height: 220)
            HStack {
                Button("Cancella") { workingStrokes = []; currentStroke = [] }
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Usa firma") {
                    strokes = workingStrokes
                    workspace.activeTool = .signature
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(workingStrokes.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 580, height: 360)
        .onAppear { workingStrokes = strokes }
    }
}

struct PasswordExportSheet: View {
    @EnvironmentObject private var workspace: PDFWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var ownerPassword = ""
    @State private var userPassword = ""
    @State private var flatten = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Proteggi una copia").font(.title2.bold())
            Text("La password proprietario è necessaria. Quella di apertura è facoltativa.")
                .foregroundStyle(.secondary)
            Form {
                SecureField("Password proprietario", text: $ownerPassword)
                SecureField("Password di apertura", text: $userPassword)
                Toggle("Appiattisci annotazioni e firma", isOn: $flatten)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Annulla") { dismiss() }
                Button("Esporta…") {
                    workspace.exportProtected(ownerPassword: ownerPassword, userPassword: userPassword, flatten: flatten)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ownerPassword.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 500, height: 300)
    }
}

struct OCRResultSheet: View {
    @Binding var text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Testo riconosciuto").font(.title2.bold())
            TextEditor(text: $text)
                .font(.body)
                .padding(6)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
            HStack {
                Text("Puoi correggere il testo prima di copiarlo.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Copia") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Button("Fine") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 650, height: 500)
    }
}
