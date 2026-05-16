import SwiftUI
import Euclid

struct DocumentView: View {
    @Binding var document: VPCBDocument

    @State private var selectedTab: Tab = .schematic
    @State private var selection: SchematicSelection = .none
    @State private var netDrawState: NetDrawState = .idle
    /// Lifted up from PhysicalView so the sidebar's DRC list can jump to a
    /// selection (and switch tabs) when the user clicks an issue.
    @State private var physicalSelection: PhysicalSelection = .none

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
        case openInFlowSimulator
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
                    Button("Open in Flow Simulator") { triggerExport(.openInFlowSimulator) }
                        .disabled(!flowSimulatorInstalled)
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
            PhysicalView(document: $document, selection: $physicalSelection)
        case .preview:
            previewView
        }
    }

    @ViewBuilder private var previewView: some View {
        if let built {
            // Keep Scene3DView mounted across rebuilds so its SCNView (and
            // therefore the user's orbit / zoom state) survives. The progress
            // indicator overlays on top instead of replacing the view — the
            // previous geometry stays visible until the new one is ready.
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
                if isBuilding {
                    ProgressView("Building plates…")
                        .padding(12)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                        .padding(.top, 56)
                }
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
                Button {
                    focusIssue(issue)
                } label: {
                    Text("• \(issue.summary)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
            if issues.count > 6 {
                Text("… and \(issues.count - 6) more")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Click handler for an issue row in the sidebar. Asks DRC for the
    /// physical-canvas selection that highlights the offending element(s),
    /// applies it, and jumps to the physical tab if we have a target there.
    private func focusIssue(_ issue: DRC.Issue) {
        guard let sel = DRC.physicalSelection(for: issue, in: document.circuit)
        else { return }
        physicalSelection = sel
        selectedTab = .physical
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
        case .openInFlowSimulator:
            openInFlowSimulator()
        }
    }

    private static let bambuStudioBundleID = "com.bambulab.bambu-studio"
    private static let flowSimulatorBundleID = "com.ionini.Flow-Simulator"

    private var bambuStudioInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bambuStudioBundleID) != nil
    }

    private var flowSimulatorInstalled: Bool { flowSimulatorAppURL != nil }

    /// Locates a *macOS* Flow Simulator build. NSWorkspace.urlForApplication
    /// can return an iOS simulator / device variant when the Xcode project
    /// is multi-platform (Launch Services indexes every bundle ID match),
    /// and trying to launch one of those with a `.usdz` fails with
    /// "cannot be opened with file …". `urlsForApplications` returns the
    /// full list so we can filter to the macOS bundle.
    ///
    /// Useful for dev workflow too — works even when the only Flow
    /// Simulator on disk is the DerivedData Debug build.
    private var flowSimulatorAppURL: URL? {
        let candidates = NSWorkspace.shared.urlsForApplications(
            withBundleIdentifier: Self.flowSimulatorBundleID
        )
        let macURLs = candidates.filter { url in
            // iOS variants live under Build/Products/{Debug,Release}-iphone*.
            // The macOS variant has no platform suffix.
            !url.path.contains("-iphonesimulator")
            && !url.path.contains("-iphoneos")
            && !url.path.contains("-appletvos")
        }
        guard !macURLs.isEmpty else { return nil }
        // Prefer the most recently modified — the user's current dev build.
        let fm = FileManager.default
        return macURLs.max { a, b in
            let aDate = (try? fm.attributesOfItem(atPath: a.path)[.modificationDate] as? Date) ?? .distantPast
            let bDate = (try? fm.attributesOfItem(atPath: b.path)[.modificationDate] as? Date) ?? .distantPast
            return aDate < bDate
        }
    }

    /// Writes the current built plates as an STL into the per-session
    /// temporary directory, then asks Bambu Studio to open the file. Slicers
    /// happily handle multi-solid STLs, so top + bottom go out as one mesh
    /// (same as the Save panel path).
    /// Writes the simulator-flavoured USDZ (named FluidVolume / inlet / outlet
    /// / gate / blocker bodies) to the sandbox temp dir and asks NSWorkspace
    /// to open it with Flow Simulator. Bodies only exist in this export —
    /// the regular STL pipeline and 3D preview ignore them.
    private func openInFlowSimulator() {
        guard let flowURL = flowSimulatorAppURL else { return }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(stlFilename).usdz")
        do {
            try SimulatorExporter.exportUSDZ(document.circuit, to: url)
        } catch {
            NSLog("vpcb: failed to write USDZ for Flow Simulator: \(error)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.open([url], withApplicationAt: flowURL, configuration: config) { _, error in
            if let error {
                NSLog("vpcb: NSWorkspace.open(Flow Simulator) failed: \(error)")
            }
        }
    }

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
