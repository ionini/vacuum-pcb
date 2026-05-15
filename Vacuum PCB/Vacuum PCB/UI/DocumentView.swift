import SwiftUI
import Euclid

struct DocumentView: View {
    @Binding var document: VPCBDocument

    @State private var selectedTab: Tab = .schematic
    @State private var selection: SchematicSelection = .none
    @State private var netDrawState: NetDrawState = .idle

    @State private var built: PlateBuilder.Output?
    @State private var isBuilding = false
    @State private var showExporter = false
    @State private var buildToken = 0
    @State private var previewMode: PreviewDisplayMode = .bodyOnly

    enum Tab: Hashable { case schematic, physical, preview }

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            VStack(spacing: 0) {
                tabPicker
                Divider()
                tabContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showExporter = true } label: {
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

    // MARK: - Tab picker

    private var tabPicker: some View {
        Picker("View", selection: $selectedTab) {
            Text("Schematic").tag(Tab.schematic)
            Text("Physical").tag(Tab.physical)
            Text("3D Preview").tag(Tab.preview)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    @ViewBuilder private var tabContent: some View {
        switch selectedTab {
        case .schematic:
            SchematicView(
                document: $document,
                selection: $selection,
                netDrawState: $netDrawState
            )
        case .physical:
            PhysicalView(document: $document)
        case .preview:
            previewView
        }
    }

    @ViewBuilder private var previewView: some View {
        if let built {
            ZStack(alignment: .top) {
                Scene3DView(
                    top: built.topPlate,
                    bottom: built.bottomPlate,
                    topFeatures: built.topFeatures,
                    bottomFeatures: built.bottomFeatures,
                    boardOutline: document.circuit.physical.boardOutline,
                    displayMode: previewMode
                )
                previewModePicker
            }
        } else if isBuilding {
            ProgressView("Building plates…")
        } else {
            ContentUnavailableView(
                "No geometry built",
                systemImage: "cube.transparent",
                description: Text("Add components and route nets, then come back here.")
            )
        }
    }

    private var previewModePicker: some View {
        Picker("Show", selection: $previewMode) {
            ForEach(PreviewDisplayMode.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .padding(.top, 8)
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
                ProgressView("Rebuilding…").controlSize(.small)
            }
            if needsPhysicalUpdate {
                Text("Physical layout out of date — open Physical tab (iter 3) to update placements / routes.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stat(_ name: String, _ value: Int) -> some View {
        HStack { Text(name); Spacer(); Text("\(value)").monospacedDigit() }
    }

    private func format(_ d: Double) -> String { String(format: "%.1f", d) }

    /// The 3D preview is driven by the physical layout, but the schematic editor
    /// can add components/nets that aren't yet placed/routed. Surface a hint.
    private var needsPhysicalUpdate: Bool {
        let placedIds = Set(document.circuit.physical.placements.map(\.componentId))
        let allIds = Set(document.circuit.logic.components.map(\.id))
        if !allIds.isSubset(of: placedIds) { return true }
        let netIds = Set(document.circuit.logic.nets.map(\.id))
        let routedIds = Set(document.circuit.physical.routes.map(\.netId))
        if !netIds.isSubset(of: routedIds) { return true }
        return false
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
