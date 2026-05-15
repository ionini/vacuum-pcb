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
    @State private var previewMode: PreviewDisplayMode = .both
    /// Set whenever the document mutates; cleared after a successful build.
    /// We don't rebuild eagerly any more — CSG is expensive and the user is
    /// almost never on the 3D Preview tab while editing.
    @State private var previewDirty: Bool = true
    /// What to do after the current build finishes, if the user kicked it off
    /// from the Export menu. Lets "Open in Bambu Studio" feel synchronous
    /// even when CSG has to run first.
    @State private var pendingExportAction: ExportAction?

    enum ExportAction {
        case saveSTL
        case openInBambuStudio
    }

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
                Menu {
                    Button("Save STL file…") { triggerExport(.saveSTL) }
                    Button("Open in Bambu Studio") { triggerExport(.openInBambuStudio) }
                        .disabled(!bambuStudioInstalled)
                } label: {
                    Label(previewDirty ? "Build & Export…" : "Export…",
                          systemImage: "square.and.arrow.up")
                }
                .disabled(isBuilding)
            }
        }
        .onChange(of: document.circuit) { _, _ in
            previewDirty = true
            // When the user is already on the 3D Preview tab, rebuild
            // immediately so settings-panel "Apply" feels responsive. On
            // other tabs we defer until they switch back. `rebuild()`
            // bumps `buildToken`, so any in-flight build is superseded.
            if selectedTab == .preview { rebuild() }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Only rebuild the CSG when the user actually wants to look at
            // the 3D preview. Avoids the per-edit Euclid CSG storm that was
            // producing the "batch:" log spam and pinning a core.
            if newTab == .preview, previewDirty, !isBuilding { rebuild() }
        }
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
        if isBuilding {
            ProgressView("Building plates…")
        } else if let built {
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
        ScrollView {
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
                drcSection

                // Settings show up on the 3D Preview tab, where they're most
                // relevant — the user is looking at what the constants
                // actually produce.
                if selectedTab == .preview {
                    Divider()
                    ManufacturingSettingsView(document: $document)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// DRC summary: how many nets are clean, how many have routing issues,
    /// and the first few issues in human-readable form. Updates live as the
    /// document changes — this whole view rebuilds on every circuit change.
    @ViewBuilder private var drcSection: some View {
        let issues = DRC.check(document.circuit)
        let netsWithIssues = Set(issues.map(\.netId)).count
        let totalNets = document.circuit.logic.nets.count
        Divider()
        if totalNets == 0 {
            Text("No nets defined")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if issues.isEmpty {
            Label("All \(totalNets) nets routed", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("\(netsWithIssues) of \(totalNets) nets have issues",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
            ForEach(issues.prefix(6)) { issue in
                Text("• \(issue.summary)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if issues.count > 6 {
                Text("… and \(issues.count - 6) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func stat(_ name: String, _ value: Int) -> some View {
        HStack { Text(name); Spacer(); Text("\(value)").monospacedDigit() }
    }

    private func format(_ d: Double) -> String { String(format: "%.1f", d) }

    // MARK: - Export

    private var stlExport: STLExportDocument? {
        guard let built else { return nil }
        return STLExportDocument(meshes: [built.topPlate, built.bottomPlate])
    }

    private var stlFilename: String {
        let c = document.circuit.logic.components.count
        return c == 0 ? "vacuum-pcb" : "vacuum-pcb-\(c)components"
    }

    // MARK: - Export actions

    private func triggerExport(_ action: ExportAction) {
        // If the preview is stale, queue the action and rebuild first. The
        // rebuild completion handler will fire the queued action exactly
        // once, so "Open in Bambu Studio" feels like a single tap.
        if previewDirty || built == nil {
            pendingExportAction = action
            if !isBuilding { rebuild() }
            return
        }
        perform(action)
    }

    private func perform(_ action: ExportAction) {
        switch action {
        case .saveSTL:
            showExporter = true
        case .openInBambuStudio:
            openInBambuStudio()
        }
    }

    private static let bambuStudioBundleID = "com.bambulab.bambu-studio"

    private var bambuStudioInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bambuStudioBundleID) != nil
    }

    /// Writes the current built plates as an STL into the per-session
    /// temporary directory, then asks Bambu Studio to open the file. Slicers
    /// happily handle multi-solid STLs, so top + bottom go out as one mesh
    /// (same as the Save panel path).
    private func openInBambuStudio() {
        guard let built else { return }
        guard let bambuURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bambuStudioBundleID) else {
            return
        }
        let combined = Mesh.merge([built.topPlate, built.bottomPlate])
        let data = combined.stlData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stlFilename).stl")
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("vpcb: failed to write STL for Bambu Studio: \(error)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: bambuURL, configuration: config) { _, error in
            if let error {
                NSLog("vpcb: NSWorkspace.open(Bambu Studio) failed: \(error)")
            }
        }
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
                self.previewDirty = false
                if let action = self.pendingExportAction {
                    self.pendingExportAction = nil
                    self.perform(action)
                }
            }
        }
    }
}
