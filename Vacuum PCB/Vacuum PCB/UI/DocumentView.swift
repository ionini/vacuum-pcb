import SwiftUI
import Euclid

struct DocumentView: View {
    @Binding var document: VPCBDocument
    /// Document-scoped UndoManager that SwiftUI's DocumentGroup
    /// publishes through the environment. macOS already routes the
    /// Edit > Undo menu and ⌘Z through it; this lets us mirror the
    /// same actions in toolbar buttons that iPad can reach without a
    /// menu bar or hardware keyboard.
    @Environment(\.undoManager) private var undoManager

    @State private var selectedTab: ViewTab = .schematic
    @State private var selection: SchematicSelection = .none
    @State private var netDrawState: NetDrawState = .idle
    /// Lifted up from PhysicalView so the sidebar's DRC list can jump to a
    /// selection (and switch tabs) when the user clicks an issue.
    @State private var physicalSelection: PhysicalSelection = .none
    /// Lifted out of PhysicalView so the Physical-tab inspector can read it
    /// and surface a "Cancel" button while routing is active — a stand-in
    /// for the Escape shortcut on iPad, where there's no hardware key.
    @State private var physicalRoutingState: RoutingState = .idle
    /// Transient ping marker on the physical canvas, set when the user
    /// clicks a DRC issue with a focal point (crossNetMerge, orphanVia,
    /// channelClearance, disconnectedPin). The canvas overlay animates it
    /// and we self-clear after ~2 seconds so the marker doesn't linger.
    @State private var issueFocus: DRC.Focus?

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

    /// Split-view + inspector visibility, exposed so the toolbar toggles
    /// match the system sidebar/inspector buttons. Every tab now has
    /// inspector content (component palette on Schematic, parking lot on
    /// Physical, manufacturing constants on Preview, simulator controls
    /// on Simulate), so the inspector defaults to open.
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic
    @State private var showInspector: Bool = true

    enum ExportAction {
        case saveSTL
        case openInBambuStudio
        case openInFlowSimulator
    }

    /// Renamed from `Tab` to avoid shadowing SwiftUI's `Tab` value type used
    /// by `TabView { Tab(...) }`.
    enum ViewTab: Hashable { case schematic, physical, preview, simulate }

    /// Created lazily on first visit to the Simulate tab so users who never
    /// open it don't pay the network-build cost. Re-created from scratch when
    /// the user leaves and comes back, which also clears the input toggles —
    /// per the v1 scope, simulation state isn't persisted.
    @State private var simulationState: SimulationState?

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 320)
        } detail: {
            detail
        }
        .inspector(isPresented: $showInspector) {
            inspector
                .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
        }
        .toolbar {
            // Undo / redo on the leading edge so they sit next to the
            // document title on iPad (the Notes/Pages convention) and
            // out of the way of the per-tab Export / Inspector items on
            // the trailing edge. macOS keeps the Edit > Undo menu as well;
            // these buttons are just a second route.
            ToolbarItem(placement: .navigation) {
                Button {
                    undoManager?.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(undoManager?.canUndo != true)
                .help("Undo (⌘Z)")
            }
            ToolbarItem(placement: .navigation) {
                Button {
                    undoManager?.redo()
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(undoManager?.canRedo != true)
                .help("Redo (⇧⌘Z)")
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
        .onChange(of: document.circuit.librarySnapshots) { _, _ in
            // `CircuitDocument.==` deliberately ignores `librarySnapshots`
            // (the snapshot dict is bookkeeping, not identity). That means
            // a transitive library update — Update from Library on a part
            // whose own `contentHash` didn't change but whose nested
            // dependency did — flips the snapshot content under an unchanged
            // key, leaves `partRefHash` alone, and so doesn't fire the
            // primary `.onChange` above. The schematic and physical views
            // still refresh because they read snapshots via `.environment`,
            // but `previewDirty` stays false and the cached `built` is
            // exported until the next real diff arrives. Mirror the doc
            // handler so snapshot-only changes still invalidate the preview.
            previewDirty = true
            if selectedTab == .preview { rebuild() }
        }
        .onChange(of: selectedTab) { _, newTab in
            // Only rebuild the CSG when the user actually wants to look at
            // the 3D preview. Avoids the per-edit Euclid CSG storm that was
            // producing the "batch:" log spam and pinning a core.
            if newTab == .preview, previewDirty, !isBuilding { rebuild() }
            // SimulateView's `.onChange(of: document.circuit)` only fires
            // while it's in the hierarchy. Edits made on other tabs leave
            // the cached SimulationState pointing at a stale network, so
            // re-sync on entry.
            if newTab == .simulate { simulationState?.rebuild(from: document.circuit) }
            // Every tab now has contextual inspector content, so
            // reveal the pane on every switch. Without it visible the
            // user loses the schematic palette / parking lot /
            // manufacturing constants / simulator controls depending on
            // the tab.
            showInspector = true
        }
        .fileExporter(
            isPresented: $showExporter,
            document: stlExport,
            contentType: .stl,
            defaultFilename: stlFilename
        ) { _ in }
        // Pinned library snapshots flow down to every sub-part-resolving view
        // (schematic symbols, physical canvas, expanded subpart) so the UI
        // matches what the CAD pipeline exports rather than reflecting
        // post-pin edits to the user's parts folder.
        .environment(\.librarySnapshots, document.circuit.librarySnapshots)
    }

    // MARK: - Detail content

    /// Switch on the sidebar's current selection. We don't use a TabView
    /// here: the navigation chooser lives in the sidebar (Mac App Store
    /// pattern), and a `switch` evaluates one view at a time so SwiftUI
    /// doesn't size the window to the widest tab's intrinsic content.
    @ViewBuilder private var detail: some View {
        switch selectedTab {
        case .schematic:
            SchematicView(
                document: $document,
                selection: $selection,
                netDrawState: $netDrawState,
                showInspector: $showInspector,
                exportMenu: exportMenu
            )
        case .physical:
            PhysicalView(
                document: $document,
                selection: $physicalSelection,
                routingState: $physicalRoutingState,
                issueFocus: $issueFocus,
                showInspector: $showInspector,
                exportMenu: exportMenu
            )
        case .preview:
            previewView
        case .simulate:
            simulateView
        }
    }

    @ViewBuilder private var simulateView: some View {
        if let state = simulationState {
            SimulateView(
                document: $document,
                state: state,
                showInspector: $showInspector,
                exportMenu: exportMenu
            )
        } else {
            // Trampoline: spin up the state then re-render. This pattern
            // (vs. computing in onAppear) keeps the @State write off the
            // view-build path so SwiftUI doesn't grouse.
            Color.clear.onAppear {
                simulationState = SimulationState(document: document.circuit)
            }
        }
    }

    @ViewBuilder private var previewView: some View {
        previewContent
            // Declared on the leaf so Export + Inspector end up rightmost
            // (parent's toolbar items render before child's).
            .toolbar {
                ToolbarItem(placement: .primaryAction) { exportMenu }
                ToolbarItem(placement: .primaryAction) {
                    InspectorToggleButton(showInspector: $showInspector)
                }
            }
    }

    @ViewBuilder private var previewContent: some View {
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
                    stencil: built.stencil,
                    boardOutline: document.circuit.physical.boardOutline,
                    displayMode: previewMode
                )
                previewModePicker
                if isBuilding {
                    ProgressView("Building plates…")
                        .padding(12)
                        .glassEffect(in: .rect(cornerRadius: 12))
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
        .glassEffect(in: .rect(cornerRadius: 10))
        .padding(.top, 8)
    }

    // MARK: - Sidebar (navigation + document info)

    /// Left column. Top section is the view chooser (Mac App Store / Mail
    /// pattern: nav lives in the sidebar). Below that are document-wide
    /// facts and DRC. Tool-specific controls (manufacturing constants,
    /// simulator inputs) live in the right-hand inspector — the macOS
    /// convention for "properties of the current view" (Xcode, Pages,
    /// Keynote, Final Cut all do this).
    /// iOS's `List(selection:)` only accepts a `Binding<Tab?>`; macOS accepts
    /// both. Wrap our non-optional `@State` in an optional binding so the
    /// same `List` works on both platforms.
    private var sidebarSelection: Binding<ViewTab?> {
        Binding(
            get: { selectedTab },
            set: { if let v = $0 { selectedTab = v } }
        )
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Views") {
                Label("Schematic", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(ViewTab.schematic)
                Label("Physical", systemImage: "square.stack.3d.up")
                    .tag(ViewTab.physical)
                Label("3D Preview", systemImage: "cube.transparent")
                    .tag(ViewTab.preview)
                Label("Simulate", systemImage: "waveform.path")
                    .tag(ViewTab.simulate)
            }
            Section("Document") {
                stat("Components", document.circuit.logic.components.count)
                stat("Nets", document.circuit.logic.nets.count)
                stat("Placements", document.circuit.physical.placements.count)
                stat("Routes", document.circuit.physical.routes.count)
                let outline = document.circuit.physical.boardOutline
                HStack {
                    Text("Board")
                    Spacer()
                    Text("\(format(outline.size.width)) × \(format(outline.size.height)) mm")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if isBuilding {
                    ProgressView("Rebuilding…").controlSize(.small)
                }
            }
            Section("Design Rules") {
                DRCSummarySection(circuit: document.circuit, onFocus: focusIssue)
            }
        }
        .listStyle(.sidebar)
    }

    /// Click handler for an issue row in the sidebar. Asks DRC for the
    /// physical-canvas selection that highlights the offending element(s),
    /// applies it, and jumps to the physical tab if we have a target there.
    /// Also drops a transient pulse marker at the issue's focal point so
    /// the user's eye lands on the offending area even when several
    /// placements light up across the board.
    private func focusIssue(_ issue: DRC.Issue) {
        let sel = DRC.physicalSelection(for: issue, in: document.circuit)
        let focal = DRC.focusPosition(for: issue, in: document.circuit)
        // Either side may be missing (e.g. an unplaced-pin issue has no
        // canvas position, a both-sub-part-internal merge has no parent-side
        // selection). Bail only if we have neither.
        guard sel != nil || focal != nil else { return }
        if let sel { physicalSelection = sel }
        selectedTab = .physical
        if let (pos, layer) = focal {
            let token = DRC.Focus(id: UUID(), position: pos, layer: layer)
            issueFocus = token
            // Self-clear after the animation runs its course so a stale
            // marker doesn't sit around forever. The id check skips the
            // clear if the user clicked another issue in the meantime.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                if issueFocus?.id == token.id { issueFocus = nil }
            }
        }
    }

    private func stat(_ name: String, _ value: Int) -> some View {
        HStack {
            Text(name)
            Spacer()
            Text("\(value)").monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func format(_ d: Double) -> String { String(format: "%.1f", d) }

    // MARK: - Inspector (right column)

    /// Right column: tool-specific properties for the active tab.
    /// macOS users expect this pane to mirror the current view (think
    /// Xcode's attributes inspector). Tabs without contextual controls
    /// show a brief placeholder so the column doesn't render empty when
    /// the user toggles it on.
    @ViewBuilder private var inspector: some View {
        switch selectedTab {
        case .preview:
            ScrollView {
                ManufacturingSettingsView(document: $document)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .simulate:
            if let state = simulationState {
                ScrollView {
                    SimulateControlsView(state: state)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Preparing simulator",
                    systemImage: "hourglass",
                    description: Text("Controls appear once the network is built.")
                )
            }
        case .physical:
            PhysicalInspector(
                document: $document,
                selection: $physicalSelection,
                routingState: $physicalRoutingState
            )
        case .schematic:
            SchematicInspector(document: $document, selection: $selection)
        }
    }

    private func tabHasInspectorContent(_ tab: ViewTab) -> Bool {
        // Every tab has inspector content now.
        true
    }

    // MARK: - Toolbar

    /// Constructed fresh each time the view re-renders so the menu
    /// reflects the current build state (`previewDirty`, `isBuilding`,
    /// installed helper apps). Passed down to per-view toolbars so they
    /// can place Export right next to the Inspector toggle.
    private var exportMenu: ExportMenuButton {
        ExportMenuButton(
            isBuilding: isBuilding,
            previewDirty: previewDirty,
            bambuStudioInstalled: bambuStudioInstalled,
            flowSimulatorInstalled: flowSimulatorInstalled,
            onSaveSTL: { triggerExport(.saveSTL) },
            onOpenBambu: { triggerExport(.openInBambuStudio) },
            onOpenFlow: { triggerExport(.openInFlowSimulator) }
        )
    }

    // MARK: - Export

    private var stlExport: STLExportDocument? {
        guard let built else { return nil }
        return STLExportDocument(meshes: [built.topPlate, built.bottomPlate, built.stencil])
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
            #if canImport(AppKit)
            openInBambuStudio()
            #else
            break
            #endif
        case .openInFlowSimulator:
            #if canImport(AppKit)
            openInFlowSimulator()
            #else
            break
            #endif
        }
    }

    #if canImport(AppKit)
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
        // makeWatertight stitches the hairline cracks Euclid's BSP CSG leaves
        // where curved surfaces meet flat ones; the preview build skips it, so
        // we apply it here on the way to the slicer.
        let combined = Mesh.merge([
            built.topPlate.makeWatertight(),
            built.bottomPlate.makeWatertight(),
            built.stencil.makeWatertight(),
        ])
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
    #else
    // iOS fallback: helper apps don't exist on iPad, so the menu items
    // stay disabled. Keeps `exportMenu` compiling without dragging in
    // any NSWorkspace references.
    private var bambuStudioInstalled: Bool { false }
    private var flowSimulatorInstalled: Bool { false }
    #endif

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

/// DRC summary block for the sidebar. Owns its own `issues` cache and
/// only recomputes when the circuit itself changes — without this the
/// inline `DRC.check(...)` ran on every parent body invalidation
/// (panning the schematic counted), and the trace flagged it as one of
/// the heavier paths during scroll. `.onChange(of:)` keeps the cache in
/// step with mutations from anywhere in the document, since `Circuit`
/// equality already covers the substantive state DRC reads.
private struct DRCSummarySection: View {
    let circuit: CircuitDocument
    let onFocus: (DRC.Issue) -> Void

    @State private var issues: [DRC.Issue] = []

    var body: some View {
        let netsWithIssues = Set(issues.map(\.netId)).count
        let totalNets = circuit.logic.nets.count
        Group {
            if totalNets == 0 {
                Label("No nets defined", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else if issues.isEmpty {
                Label("All \(totalNets) nets routed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("\(netsWithIssues) of \(totalNets) nets have issues",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(issues.prefix(6)) { issue in
                    Button {
                        onFocus(issue)
                    } label: {
                        Text(issue.summary)
                            .font(.caption)
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
        .onAppear { issues = DRC.check(circuit) }
        .onChange(of: circuit) { _, new in issues = DRC.check(new) }
    }
}

/// Toolbar button that toggles the document inspector. Lives outside
/// DocumentView so each tab's leaf toolbar can declare it as its last
/// item — that's what makes it land as the rightmost toolbar button
/// (parent's primaryAction items render before child's in SwiftUI's
/// macOS toolbar merge).
struct InspectorToggleButton: View {
    @Binding var showInspector: Bool

    var body: some View {
        Button {
            showInspector.toggle()
        } label: {
            Label("Inspector", systemImage: "sidebar.right")
        }
        .help(showInspector ? "Hide inspector" : "Show inspector")
    }
}

/// Document-level Export menu, factored out so each per-view toolbar can
/// declare it immediately before `InspectorToggleButton` — that keeps
/// both rightmost and adjacent (Export → Inspector). The closure form
/// avoids leaking DocumentView's `ExportAction` enum into call sites.
struct ExportMenuButton: View {
    let isBuilding: Bool
    let previewDirty: Bool
    let bambuStudioInstalled: Bool
    let flowSimulatorInstalled: Bool
    let onSaveSTL: () -> Void
    let onOpenBambu: () -> Void
    let onOpenFlow: () -> Void

    var body: some View {
        Menu {
            Button("Save STL file…", action: onSaveSTL)
            Button("Open in Bambu Studio", action: onOpenBambu)
                .disabled(!bambuStudioInstalled)
            Button("Open in Flow Simulator", action: onOpenFlow)
                .disabled(!flowSimulatorInstalled)
        } label: {
            Label(previewDirty ? "Build & Export…" : "Export…",
                  systemImage: "square.and.arrow.up")
        }
        .disabled(isBuilding)
    }
}
