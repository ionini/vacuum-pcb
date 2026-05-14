import SwiftUI
import Euclid

struct DocumentView: View {
    @Binding var document: VPCBDocument

    @State private var built: PlateBuilder.Output?
    @State private var isBuilding = false
    @State private var buildError: String?
    @State private var showExporter = false
    @State private var buildToken = 0

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 280, maxWidth: 360)
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showExporter = true
                } label: {
                    Label("Export STL…", systemImage: "square.and.arrow.up")
                }
                .disabled(built == nil)
            }
        }
        .onAppear { rebuild() }
        .onChange(of: document.circuit) { _, _ in rebuild() }
        .fileExporter(
            isPresented: $showExporter,
            document: stlExport,
            contentType: .stl,
            defaultFilename: stlFilename
        ) { _ in }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Document").font(.title3).bold()

            stat("Components", document.circuit.logic.components.count)
            stat("Nets",       document.circuit.logic.nets.count)
            stat("Placements", document.circuit.physical.placements.count)
            stat("Routes",     document.circuit.physical.routes.count)

            Divider()

            let outline = document.circuit.physical.boardOutline
            Text("Board: \(format(outline.size.width)) × \(format(outline.size.height)) mm")
                .font(.caption)
                .foregroundStyle(.secondary)

            if isBuilding {
                ProgressView("Building plates…")
                    .controlSize(.small)
            }
            if let buildError {
                Text(buildError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ name: String, _ value: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(value)").monospacedDigit()
        }
    }

    private func format(_ d: Double) -> String { String(format: "%.1f", d) }

    // MARK: - Preview

    private var preview: some View {
        Group {
            if let built {
                Scene3DView(
                    top: built.topPlate,
                    bottom: built.bottomPlate,
                    boardOutline: document.circuit.physical.boardOutline
                )
            } else if isBuilding {
                ProgressView()
            } else {
                ContentUnavailableView(
                    "No geometry built",
                    systemImage: "cube.transparent",
                    description: Text("Open or create a document with placed components.")
                )
            }
        }
    }

    // MARK: - Export

    private var stlExport: STLExportDocument? {
        guard let built else { return nil }
        return STLExportDocument(meshes: [built.topPlate, built.bottomPlate])
    }

    private var stlFilename: String {
        let c = document.circuit.logic.components.count
        return c == 0 ? "vacuum-pcb" : "vacuum-pcb-\(c)components"
    }

    // MARK: - Build

    private func rebuild() {
        buildToken += 1
        let token = buildToken
        isBuilding = true
        buildError = nil
        let snapshot = document.circuit
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlateBuilder.build(snapshot)
            DispatchQueue.main.async {
                guard token == buildToken else { return }
                self.built = result
                self.isBuilding = false
            }
        }
    }
}
