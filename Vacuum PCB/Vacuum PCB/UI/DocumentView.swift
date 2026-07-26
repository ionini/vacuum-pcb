import SwiftUI
import Euclid
import UniformTypeIdentifiers

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
    /// Per-plate physical volumes of the printed board (subparts flattened),
    /// recomputed alongside each `rebuild()`. Drives the Preview tab's Volumes
    /// inspector and the 3D highlight.
    @State private var volumes: [Volume] = []
    /// Which volumes (by `Volume.id`) are highlighted in the 3D preview. One
    /// when the user clicks a row in the Volumes inspector; two (in contrasting
    /// colours) when jumped here from a collision in the Validate tab.
    @State private var highlightedVolumeIDs: [String] = []
    /// Cavity mesh per `Volume.id`, rebuilt off-thread on each `rebuild()` and
    /// handed to `Scene3DView`, which turns each into a hidden, hit-testable node
    /// (click-to-select) and glows the highlighted subset.
    @State private var volumeMeshes: [String: Mesh] = [:]
    @State private var isBuilding = false
    @State private var showExporter = false
    /// Bambu Studio export: a folder document (model + modifier STLs + manifest)
    /// prebuilt off-thread and handed to `.fileExporter`.
    @State private var showBambuExporter = false
    @State private var bambuExportDocument: BambuExportDocument?
    @State private var buildToken = 0
    /// Bumped whenever the built geometry (plates + volume cavity meshes) is
    /// swapped in, so `Scene3DView` rebuilds its scene nodes only then — not on a
    /// cheap highlight or layer-visibility change.
    @State private var geometryRevision = 0
    /// Per-element visibility of the 3D preview (which plates / channels / mold
    /// parts are shown). Starts on the plates-plus-channels preset.
    @State private var previewVisibility: PreviewVisibility = .both
    /// Print-envelope (modifier volume) overlay mesh + its own revision, so a
    /// padding tweak refreshes just this node — not the whole scene. Rebuilt
    /// alongside every full `rebuild()` and by `rebuildEnvelope()` when the
    /// padding slider commits.
    @State private var envelopeMesh: Mesh = Mesh([])
    @State private var envelopeRevision = 0
    /// Which region the preview overlay (and a fresh export) shows:
    /// "pneumatics" = the envelope around the features, "voids" = its
    /// complement (what the void modifier will downgrade — includes the screw
    /// and connector keep-outs the positive envelope can't show). Persisted.
    @AppStorage("previewEnvelopeStyle") private var envelopeStyleRaw =
        BambuExport.ModifierStyle.pneumatics.rawValue
    /// The voids mesh is real CSG (seconds on a dense board), so it is built
    /// lazily: skipped while the overlay is hidden and flagged stale instead.
    @State private var envelopeStale = false
    /// A voids rebuild is running; shows a small spinner beside the slider.
    @State private var isBuildingEnvelope = false
    @State private var envelopeToken = 0
    /// Live value while the envelope-padding slider is mid-drag; nil when idle
    /// (the document's `modifierMarginXY` is then the truth). Committing the
    /// drag writes the document and clears this — same draft idea as the
    /// Manufacturing inspector, so dragging doesn't spam document mutations.
    @State private var envelopePaddingDraft: Double?
    /// Opacity of the printed body (plates / silicone sheet / casting frame)
    /// in the 3D preview; feature channels stay opaque. Persisted so the
    /// user's preferred translucency survives relaunches.
    @AppStorage("previewBodyOpacity") private var previewBodyOpacity = 0.55
    /// When off, testing points are excluded from the built geometry entirely —
    /// no bore in the preview and none in the exported STL. Unlike the
    /// `PreviewVisibility` flags (which only hide scene nodes), this feeds the
    /// build, so toggling it forces a rebuild. Persisted like the schematic's
    /// test-point toggle.
    @AppStorage("previewIncludeTestPoints") private var includeTestPoints = true
    /// Survives the Preview tab being switched away and back: `detail` is a
    /// `switch`, so leaving Preview tears `Scene3DView` (and the camera living
    /// inside its SCNView) down. Holding the pose here lets the rebuilt view
    /// replay the user's orbit / zoom instead of snapping to the iso default.
    @State private var cameraStore = Scene3DCameraStore()
    /// Same arrangement for the Simulate tab's 3D canvas — a separate store,
    /// so the two 3D views keep independent orbits.
    @State private var simulateCameraStore = Scene3DCameraStore()
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
        case exportBambu
        case openInBambuStudio
        case openInBambuWithModifier
        case openInBambuWithVoidModifier
        case openInFlowSimulator
    }

    /// Renamed from `Tab` to avoid shadowing SwiftUI's `Tab` value type used
    /// by `TabView { Tab(...) }`.
    enum ViewTab: Hashable { case schematic, physical, preview, simulate, validate }

    /// Created lazily on first visit to the Simulate tab so users who never
    /// open it don't pay the network-build cost. Re-created from scratch when
    /// the user leaves and comes back, which also clears the input toggles —
    /// per the v1 scope, simulation state isn't persisted.
    @State private var simulationState: SimulationState?

    /// Validation results live here (not in `ValidateView`) so they persist
    /// across tab switches; `validationModel.invalidate()` clears them when the
    /// design changes.
    @State private var validationModel = ValidationModel()

    /// DSL test runner state for the Simulate tab's bottom drawer (pasted
    /// script, pin mapping, polarity, results). Owned here — like
    /// `validationModel` — so it survives leaving and returning to Simulate.
    /// Not persisted into the `.vpcb` (matches the v1 simulation-state scope).
    @State private var testModel = SimTestModel()

    /// How many placed subparts are pinned to an older library version.
    /// Drives the sidebar's Library section (below Design Rules) with its
    /// bulk "Update All from Library" button. Recomputed debounced — the
    /// staleness check hashes whole library documents, too heavy to run
    /// synchronously on every drag tick of the circuit `onChange`.
    @State private var outdatedSubparts = 0
    @State private var outdatedRecompute: Task<Void, Never>?

    #if canImport(AppKit)
    /// Opens library `.vpcb` files for the View-menu "Open All Subparts as
    /// Tabs" command (published to the menu via `focusedSceneValue`).
    @Environment(\.openDocument) private var openDocument
    #endif

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
            // Editing the design invalidates any prior validation run; the
            // panel resets to "Not run yet". Tab switches don't touch the
            // circuit, so results survive those (the whole point of hoisting
            // the model up here rather than keeping it in ValidateView).
            validationModel.invalidate()
            // When the user is already on the 3D Preview tab, rebuild
            // immediately so settings-panel "Apply" feels responsive. On
            // other tabs we defer until they switch back. `rebuild()`
            // bumps `buildToken`, so any in-flight build is superseded.
            if selectedTab == .preview { rebuild() }
            // Crossing into assembly mode hides the Physical and 3D
            // Preview tabs (and the Simulate physical canvas). If the
            // user was on one of those tabs when they confirmed the
            // assembly-mode prompt, redirect to a tab that still exists.
            if document.circuit.isAssembly, !visibleTabs.contains(selectedTab) {
                selectedTab = .schematic
            }
            scheduleOutdatedRecompute()
        }
        .onChange(of: previewVisibility) { _, newValue in
            // The voids overlay is built lazily; switching it on with a stale
            // (or dropped) mesh triggers the deferred build.
            if newValue.contains(.envelope), envelopeStale, !isBuildingEnvelope {
                rebuildEnvelope()
            }
        }
        .onChange(of: envelopeStyleRaw) { _, _ in
            // Style switch invalidates the current overlay outright.
            if previewVisibility.contains(.envelope) {
                rebuildEnvelope()
            } else {
                envelopeMesh = Mesh([])
                envelopeRevision &+= 1
                envelopeStale = true
            }
        }
        .onChange(of: includeTestPoints) { _, _ in
            // This flag feeds the build (unlike the scene-visibility toggles),
            // so a change means the cached geometry is stale.
            previewDirty = true
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
            scheduleOutdatedRecompute()
        }
        // Fires immediately on subscription (initial count) and again on
        // every library re-index — including the folder watcher's reload
        // right after a part is saved in another window tab. That's what
        // flips the sidebar's Library section on without any user action.
        .onReceive(PartsLibrary.shared.$parts) { _ in
            scheduleOutdatedRecompute()
        }
        #if canImport(AppKit)
        // Publishes the "Open All Subparts as Tabs" action to the View
        // menu for whichever document window is frontmost.
        .focusedSceneValue(\.openAllSubpartTabs, OpenAllSubpartTabsAction(
            enabled: document.circuit.logic.components.contains { $0.kind == .subpart },
            run: { SubpartTabs.openAll(from: document.circuit, openDocument: openDocument) }
        ))
        #endif
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
            // Reveal the inspector on tabs that have contextual content
            // (schematic palette / parking lot / manufacturing constants /
            // simulator controls). The self-contained Validate panel has no
            // inspector, so hide the empty pane there.
            showInspector = tabHasInspectorContent(newTab)
        }
        .fileExporter(
            isPresented: $showExporter,
            document: stlExport,
            contentType: .stl,
            defaultFilename: stlFilename
        ) { _ in }
        // "Export for Bambu Studio": a folder holding the model + modifier STLs
        // (+ manifest). Written as a directory so the two aligned STLs land
        // side by side, ready to multi-select in Bambu Studio.
        //
        // Hosted on a separate (background) view: SwiftUI gives each view a
        // single file-exporter presentation slot, so stacking this directly on
        // the same view as the STL exporter above lets the later modifier win
        // and silently swallows the STL "Save STL file…" picker. Isolating it
        // on its own node keeps both pickers independently presentable.
        .background {
            Color.clear
                .fileExporter(
                    isPresented: $showBambuExporter,
                    document: bambuExportDocument,
                    contentType: .folder,
                    defaultFilename: "\(bambuBaseName)_bambu"
                ) { _ in bambuExportDocument = nil }
        }
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
        case .validate:
            ValidateView(model: validationModel, document: $document, onAction: handleValidationAction)
        }
    }

    /// Jump to the Simulate tab with a specific parameter set applied — used by
    /// the Validate panel to reopen a failing margin corner so the user can
    /// watch it interactively. Reuses the existing simulator if present (so
    /// their input toggles survive); otherwise spins one up.
    private func openInSimulate(_ params: SimulationParameters) {
        if simulationState == nil {
            simulationState = SimulationState(document: document.circuit)
        }
        simulationState?.params = params
        selectedTab = .simulate
    }

    /// Dispatch a Validate-panel follow-up: a margin corner reopens in Simulate;
    /// a collision jumps to the 3D preview with the two cavities highlighted in
    /// contrasting colours.
    private func handleValidationAction(_ target: Validators.ReportAction.Target) {
        switch target {
        case .openInSimulate(let params):
            openInSimulate(params)
        case .showVolumes(let ids):
            highlightedVolumeIDs = ids
            selectedTab = .preview
        }
    }

    @ViewBuilder private var simulateView: some View {
        if let state = simulationState {
            SimulateView(
                document: $document,
                state: state,
                testModel: testModel,
                showInspector: $showInspector,
                exportMenu: exportMenu,
                simulate3DCameraStore: simulateCameraStore
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
                    moldFrame: built.moldFrame,
                    envelope: envelopeMesh,
                    envelopeRevision: envelopeRevision,
                    boardOutline: document.circuit.physical.boardOutline,
                    visibility: previewVisibility,
                    bodyOpacity: previewBodyOpacity,
                    volumeMeshes: volumeMeshes,
                    highlightedIDs: highlightedVolumeIDs,
                    geometryRevision: geometryRevision,
                    onPickVolume: pickVolume,
                    cameraStore: cameraStore
                )
                previewControls
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

    /// Floating overlay at the top of the 3D preview: the preset segmented
    /// picker (one-click visibility combinations) plus a "Layers" menu for
    /// toggling individual plates / channels / mold parts.
    private var previewControls: some View {
        HStack(spacing: 8) {
            Picker("Show", selection: presetSelection) {
                ForEach(PreviewDisplayMode.allCases, id: \.self) { mode in
                    Text(mode.label).tag(Optional(mode))
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            Menu {
                Section("Plates") {
                    Toggle("Top plate", isOn: visibilityBinding(.topPlate))
                    Toggle("Bottom plate", isOn: visibilityBinding(.bottomPlate))
                }
                Section("Channels") {
                    Toggle("Top channels", isOn: visibilityBinding(.topChannels))
                    Toggle("Bottom channels", isOn: visibilityBinding(.bottomChannels))
                }
                Section("Casting") {
                    Toggle("Silicone sheet", isOn: visibilityBinding(.stencil))
                    Toggle("Casting frame", isOn: visibilityBinding(.mold))
                }
                Section("Testing") {
                    // Not a scene-visibility flag: this rebuilds the geometry so
                    // the bores leave the preview *and* the exported STL.
                    Toggle("Test points", isOn: $includeTestPoints)
                }
                Section("Print") {
                    Toggle("Print envelope", isOn: visibilityBinding(.envelope))
                    Picker("Region", selection: $envelopeStyleRaw) {
                        Text("Pneumatics (keep solid)")
                            .tag(BambuExport.ModifierStyle.pneumatics.rawValue)
                        Text("Voids (downgrade)")
                            .tag(BambuExport.ModifierStyle.voids.rawValue)
                    }
                }
            } label: {
                Label("Layers", systemImage: "square.3.layers.3d")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            HStack(spacing: 5) {
                Image(systemName: "circle.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: $previewBodyOpacity, in: 0.1...1.0)
                    .controlSize(InputPlatform.isTouch ? .regular : .small)
                    .frame(width: InputPlatform.isTouch ? 120 : 90)
            }
            .help("Body opacity — how solid the printed plates (and silicone " +
                  "sheet / casting frame) render. Channels stay opaque.")

            if previewVisibility.contains(.envelope) {
                envelopePaddingControl
                if isBuildingEnvelope {
                    ProgressView()
                        .controlSize(.small)
                        .help("Building the envelope…")
                }
            }
        }
        .padding(8)
        .glassEffect(in: .rect(cornerRadius: 10))
        .padding(.top, 8)
    }

    /// Envelope padding: live-drafted slider + value readout. Dragging shows
    /// the value; releasing commits it to the document (both margins — one
    /// isotropic leak-barrier thickness; the Manufacturing inspector still
    /// edits XY and Z separately) and regenerates just the envelope mesh.
    private var envelopePaddingControl: some View {
        let current = envelopePaddingDraft ?? document.circuit.manufacturing.modifierMarginXY
        return HStack(spacing: 5) {
            Image(systemName: "square.dashed")
                .font(.caption)
                .foregroundStyle(.purple)
            Slider(
                value: Binding(
                    get: { envelopePaddingDraft ?? document.circuit.manufacturing.modifierMarginXY },
                    set: { envelopePaddingDraft = $0 }
                ),
                in: 0.2...4.0,
                onEditingChanged: { editing in
                    guard !editing, let value = envelopePaddingDraft else { return }
                    document.circuit.manufacturing.modifierMarginXY = value
                    document.circuit.manufacturing.modifierMarginZ = value
                    envelopePaddingDraft = nil
                    rebuildEnvelope()
                }
            )
            .controlSize(InputPlatform.isTouch ? .regular : .small)
            .frame(width: InputPlatform.isTouch ? 120 : 90)
            Text(String(format: "%.1f mm", current))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)
        }
        .help("Print-envelope padding — the wall of material around every " +
              "channel / valve / via the modifier volume claims (e.g. for " +
              "solid infill). Committing a drag sets both the XY and Z " +
              "margins; fine-tune them separately in Manufacturing settings.")
    }

    /// The overlay style as its enum (AppStorage can only hold the raw value).
    private var envelopeStyle: BambuExport.ModifierStyle {
        BambuExport.ModifierStyle(rawValue: envelopeStyleRaw) ?? .pneumatics
    }

    /// Regenerate just the print-envelope mesh from the current document — no
    /// plate rebuild. Pneumatics is near-instant; voids is real CSG (seconds
    /// on a dense board), hence the token guard and the busy flag.
    private func rebuildEnvelope() {
        var snapshot = document.circuit
        if !includeTestPoints { snapshot.physical.testPoints = [] }
        let style = envelopeStyle
        envelopeToken += 1
        let token = envelopeToken
        isBuildingEnvelope = true
        DispatchQueue.global(qos: .userInitiated).async {
            let envelope: Mesh
            switch style {
            case .pneumatics:
                envelope = PlateBuilder.buildModifier(
                    snapshot, margins: .init(snapshot.manufacturing))
            case .voids:
                envelope = PlateBuilder.buildInvertedModifier(
                    snapshot, margins: .init(snapshot.manufacturing))
            }
            DispatchQueue.main.async {
                guard token == envelopeToken else { return }
                self.envelopeMesh = envelope
                self.envelopeRevision &+= 1
                self.envelopeStale = false
                self.isBuildingEnvelope = false
            }
        }
    }

    /// Maps the per-element visibility set to/from the named presets. The getter
    /// returns the matching preset, or nil (no segment selected) once the user
    /// has toggled individual layers away from any preset.
    private var presetSelection: Binding<PreviewDisplayMode?> {
        Binding(
            get: { PreviewDisplayMode.allCases.first { $0.visibility == previewVisibility } },
            set: { if let mode = $0 { previewVisibility = mode.visibility } }
        )
    }

    /// On/off binding for one `PreviewVisibility` element, used by the Layers menu.
    private func visibilityBinding(_ element: PreviewVisibility) -> Binding<Bool> {
        Binding(
            get: { previewVisibility.contains(element) },
            set: { on in
                if on { previewVisibility.insert(element) }
                else  { previewVisibility.remove(element) }
            }
        )
    }

    /// Click-to-select from the 3D scene: toggle the clicked cavity (matching the
    /// Volumes inspector's single-select), or clear when the click missed.
    private func pickVolume(_ id: String?) {
        guard let id else { highlightedVolumeIDs = []; return }
        highlightedVolumeIDs = (highlightedVolumeIDs == [id]) ? [] : [id]
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

    /// Tabs that should appear in the sidebar for the current document.
    /// Assembly-mode docs have no single plate stack, so Physical and 3D
    /// Preview drop out; the Simulate tab stays, just with its physical
    /// canvas hidden inside.
    private var visibleTabs: [ViewTab] {
        if document.circuit.isAssembly {
            return [.schematic, .simulate, .validate]
        }
        return [.schematic, .physical, .preview, .simulate, .validate]
    }

    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Views") {
                ForEach(visibleTabs, id: \.self) { tab in
                    sidebarTabRow(tab).tag(tab)
                }
                if document.circuit.isAssembly {
                    Label("Assembly mode", systemImage: "puzzlepiece.fill")
                        .foregroundStyle(.indigo)
                        .font(.caption.bold())
                }
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
                // Exact pour volume once built (counts connector protrusions);
                // a board-only estimate before the first build.
                let mL = built.map { $0.siliconeVolumeMM3 / 1000 }
                    ?? Mold.siliconeVolumeML(outline: outline, m: document.circuit.manufacturing)
                HStack {
                    Text("Silicone")
                    Spacer()
                    Text("\(String(format: "%.2f", mL)) mL")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .help("Volume of silicone to pour into the casting frame: cavity footprint (board + connector protrusions, grown by the casting margin) × silicone thickness.")
                if isBuilding {
                    ProgressView("Rebuilding…").controlSize(.small)
                }
            }
            Section("Design Rules") {
                DRCSummarySection(circuit: document.circuit, onFocus: focusIssue)
            }
            // Only materialises when something is actually stale — an
            // always-on "Library: up to date" row would just be noise.
            if outdatedSubparts > 0 {
                Section("Library") {
                    Label(outdatedSubparts == 1
                            ? "1 subpart out of date"
                            : "\(outdatedSubparts) subparts out of date",
                          systemImage: "arrow.triangle.2.circlepath")
                        .foregroundStyle(.orange)
                        .font(.caption)
                    Button("Update All from Library") { updateAllSubparts() }
                        .controlSize(.small)
                        .help("Re-pin every out-of-date subpart instance to the current library version — same as clicking each instance's own Update from Library button, without having to select them. Up-to-date instances are untouched.")
                }
            }
        }
        .listStyle(.sidebar)
    }

    /// Debounced re-count of stale subpart pins. A save in a library tab
    /// lands as a `PartsLibrary` reload burst, and drags mutate the circuit
    /// every frame — one hash pass ~0.25 s after the last trigger covers
    /// both without hashing library docs per tick.
    private func scheduleOutdatedRecompute() {
        outdatedRecompute?.cancel()
        outdatedRecompute = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            outdatedSubparts = document.circuit.outdatedSubpartCount()
        }
    }

    /// Bulk Update-from-Library: re-pins every out-of-date subpart instance
    /// (transitive edits included) in one shot. `refreshAllSnapshots` leaves
    /// already-current instances untouched, so this is exactly "update all
    /// subcomponents that need updating".
    private func updateAllSubparts() {
        var circuit = document.circuit
        if CircuitDocument.refreshAllSnapshots(&circuit, libraryLookup: CircuitDocument.sharedLibraryLookup) {
            document.circuit = circuit
        }
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

    @ViewBuilder private func sidebarTabRow(_ tab: ViewTab) -> some View {
        switch tab {
        case .schematic:
            Label("Schematic", systemImage: "point.3.connected.trianglepath.dotted")
        case .physical:
            Label("Physical", systemImage: "square.stack.3d.up")
        case .preview:
            Label("3D Preview", systemImage: "cube.transparent")
        case .simulate:
            Label("Simulate", systemImage: "waveform.path")
        case .validate:
            Label("Validate", systemImage: "checkmark.seal")
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
                VStack(alignment: .leading, spacing: 18) {
                    VolumeListView(
                        volumes: volumes,
                        highlighted: Set(highlightedVolumeIDs),
                        onSelect: { id in
                            highlightedVolumeIDs = (highlightedVolumeIDs == [id]) ? [] : [id]
                        })
                    Divider()
                    ManufacturingSettingsView(document: $document)
                }
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
        case .validate:
            EmptyView()
        }
    }

    private func tabHasInspectorContent(_ tab: ViewTab) -> Bool {
        // The Validate panel is self-contained; everything else has an inspector.
        tab != .validate
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
            isAssembly: document.circuit.isAssembly,
            onSaveSTL: { triggerExport(.saveSTL) },
            onExportBambu: { triggerExport(.exportBambu) },
            onOpenBambu: { triggerExport(.openInBambuStudio) },
            onOpenBambuWithModifier: { triggerExport(.openInBambuWithModifier) },
            onOpenBambuWithVoidModifier: { triggerExport(.openInBambuWithVoidModifier) },
            onOpenFlow: { triggerExport(.openInFlowSimulator) }
        )
    }

    // MARK: - Export

    private var stlExport: STLExportDocument? {
        guard let built else { return nil }
        let meshes = [built.topPlate, built.bottomPlate, built.stencil, built.moldFrame]
            .filter { !$0.isEmpty }
        return STLExportDocument(meshes: meshes)
    }

    private var stlFilename: String {
        let c = document.circuit.logic.components.count
        return c == 0 ? "vacuum-pcb" : "vacuum-pcb-\(c)components"
    }

    /// Filesystem-safe base for the Bambu export's files (`<base>_model.stl`,
    /// `<base>_modifier.stl`, …).
    private var bambuBaseName: String { BambuExport.sanitizedBaseName(stlFilename) }

    /// Builds the Bambu export payload (model + modifier STLs + manifest) off
    /// the main thread — reusing the already-built preview plates for the
    /// model — then presents the folder exporter. `triggerExport` has already
    /// ensured `built` is fresh (rebuilding first if the preview was dirty).
    private func prepareBambuExport() {
        guard let built else { return }
        // Match the snapshot the preview built from, so the modifier lines up
        // with the plates (test points excluded from both when toggled off).
        var snapshot = document.circuit
        if !includeTestPoints { snapshot.physical.testPoints = [] }
        let base = bambuBaseName
        isBuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = BambuExport.payload(doc: snapshot, baseName: base,
                                              margins: .init(snapshot.manufacturing),
                                              prebuiltModel: built)
            DispatchQueue.main.async {
                self.bambuExportDocument = BambuExportDocument(files: payload.files)
                self.isBuilding = false
                self.showBambuExporter = true
            }
        }
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
        case .exportBambu:
            prepareBambuExport()
        case .openInBambuStudio:
            #if canImport(AppKit)
            openInBambuStudio()
            #else
            break
            #endif
        case .openInBambuWithModifier:
            #if canImport(AppKit)
            openInBambuStudio(withModifier: true)
            #else
            break
            #endif
        case .openInBambuWithVoidModifier:
            #if canImport(AppKit)
            openInBambuStudio(withModifier: true, style: .voids)
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

    private func openInBambuStudio(withModifier: Bool = false,
                                   style: BambuExport.ModifierStyle = .pneumatics) {
        guard let built else { return }
        guard let bambuURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bambuStudioBundleID) else {
            return
        }
        if withModifier {
            openInBambuStudioWithModifier(bambuURL: bambuURL, built: built, style: style)
            return
        }
        // makeWatertight stitches the hairline cracks Euclid's BSP CSG leaves
        // where curved surfaces meet flat ones; the preview build skips it, so
        // we apply it here on the way to the slicer. Concatenate the separate
        // solids' polygons into one multi-solid mesh (Mesh(_:), no CSG) rather
        // than Mesh.merge, which would boolean-union the concentric plates.
        let combined = Mesh(
            [built.topPlate, built.bottomPlate, built.stencil, built.moldFrame]
                .filter { !$0.isEmpty }
                .flatMap { $0.makeWatertight().polygons }
        )
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

    /// Builds the model + print-critical modifier (off-thread, reusing the
    /// already-built plates for the model) into the temp dir and opens *both*
    /// STLs in Bambu Studio at once — that's what makes Bambu offer to load
    /// them as a single (multipart) object. The two share PlateBuilder's
    /// coordinate space, so they stay aligned; the user then switches the
    /// `_modifier` part to a Modifier. No manifest is written for this path.
    private func openInBambuStudioWithModifier(bambuURL: URL, built: PlateBuilder.Output,
                                               style: BambuExport.ModifierStyle = .pneumatics) {
        // Match the preview's snapshot so the modifier lines up with the plates.
        var snapshot = document.circuit
        if !includeTestPoints { snapshot.physical.testPoints = [] }
        let base = bambuBaseName
        isBuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let payload = BambuExport.payload(doc: snapshot, baseName: base,
                                              margins: .init(snapshot.manufacturing),
                                              style: style,
                                              includeManifest: false, prebuiltModel: built)
            let dir = FileManager.default.temporaryDirectory
            var urls: [URL] = []
            do {
                // Only the model + modifier pair goes to Bambu — handing the
                // stencil/mold along would fold them into the same multipart
                // object when the user answers "yes" to the load-together
                // prompt. They're separate objects; use the folder export
                // when they're needed.
                for file in payload.files where payload.pairFilenames.contains(file.name) {
                    let url = dir.appendingPathComponent(file.name)
                    try file.data.write(to: url, options: .atomic)
                    urls.append(url)
                }
            } catch {
                NSLog("vpcb: failed to write STLs for Bambu Studio: \(error)")
                DispatchQueue.main.async { self.isBuilding = false }
                return
            }
            DispatchQueue.main.async {
                self.isBuilding = false
                let config = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.open(urls, withApplicationAt: bambuURL, configuration: config) { _, error in
                    if let error {
                        NSLog("vpcb: NSWorkspace.open(Bambu Studio) failed: \(error)")
                    }
                }
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
        var snapshot = document.circuit
        // Excluding test points here keeps them out of both the preview mesh
        // and the exported STL (both read the same `built`), while leaving the
        // editor and Simulate views — which read the document directly —
        // untouched.
        if !includeTestPoints { snapshot.physical.testPoints = [] }
        let style = envelopeStyle
        let wantsEnvelope = previewVisibility.contains(.envelope)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = PlateBuilder.build(snapshot)
            // Print-envelope overlay for the same snapshot. The pneumatics
            // style is cheap (polygon concatenation) and rides along on every
            // rebuild; the voids style is real CSG, so it is only built here
            // when the overlay is actually visible — otherwise it's flagged
            // stale and built on demand when the user switches it on.
            let envelope: Mesh?
            switch style {
            case .pneumatics:
                envelope = PlateBuilder.buildModifier(
                    snapshot, margins: .init(snapshot.manufacturing))
            case .voids:
                envelope = wantsEnvelope
                    ? PlateBuilder.buildInvertedModifier(
                        snapshot, margins: .init(snapshot.manufacturing))
                    : nil
            }
            // Whole printed board, subparts flattened — matches what prints, so
            // the volume cavities line up with the geometry above.
            let vols = physicalVolumes(snapshot.flattenedForSimulation().document)
            // Cavity meshes for the scene's per-volume pick / highlight nodes.
            // Cheap (polygon concatenation, no CSG), so building all of them here
            // — off the main thread, alongside the volume decomposition — is fine.
            let m = snapshot.manufacturing
            let vmeshes = Dictionary(uniqueKeysWithValues:
                vols.map { ($0.id, PlateBuilder.volumeMesh(for: $0, m)) })
            DispatchQueue.main.async {
                guard token == buildToken else { return }
                self.built = result
                self.volumes = vols
                self.volumeMeshes = vmeshes
                self.geometryRevision &+= 1
                if let envelope {
                    self.envelopeMesh = envelope
                    self.envelopeStale = false
                } else {
                    // Skipped voids build: drop the old mesh (it may show the
                    // wrong style) and rebuild when the overlay comes back.
                    self.envelopeMesh = Mesh([])
                    self.envelopeStale = true
                }
                self.envelopeRevision &+= 1
                // Drop any highlighted ids the rebuild no longer has.
                let live = Set(vols.map(\.id))
                self.highlightedVolumeIDs.removeAll { !live.contains($0) }
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
    /// Partially-routed nets — some legs drawn, at least one connection still
    /// missing. `DRC.check` only flags a net with *zero* routes ("no route
    /// drawn"), so without this the sidebar would call a half-routed net
    /// "routed" and stay green while the Validate tab's connectivity gate
    /// (which also reads the ratsnest) flags it.
    @State private var unrouted: [RatsnestEdge] = []

    var body: some View {
        // Nets carrying a hard problem — a DRC error or an unrouted
        // connection. Warnings (walls under the preferred comfort wall but
        // printable) get their own yellow section below so they neither
        // repaint the header red nor hide behind a green tick.
        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        let problemNetIds = Set(errors.map(\.netId)).union(unrouted.map(\.netId))
        let totalNets = circuit.logic.nets.count
        Group {
            if totalNets == 0 {
                Label("No nets defined", systemImage: "circle.dashed")
                    .foregroundStyle(.secondary)
            } else if problemNetIds.isEmpty {
                Label("All \(totalNets) nets routed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Label("\(problemNetIds.count) of \(totalNets) nets have issues",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                ForEach(errors.prefix(6)) { issue in
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
                // Unrouted-connection rows. Not focusable (a ratsnest edge isn't
                // a DRC.Issue), but they surface the same warning the Validate
                // tab raises so the sidebar can't read green on a routing gap.
                ForEach(Array(unrouted.prefix(6).enumerated()), id: \.offset) { _, edge in
                    Text("\(edge.netLabel): connection not routed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                let extra = max(0, errors.count - 6) + max(0, unrouted.count - 6)
                if extra > 0 {
                    Text("… and \(extra) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !warnings.isEmpty {
                Label("\(warnings.count) wall warning\(warnings.count == 1 ? "" : "s")",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.yellow)
                ForEach(warnings.prefix(4)) { issue in
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
                if warnings.count > 4 {
                    Text("… and \(warnings.count - 4) more")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .onAppear { recompute(circuit) }
        .onChange(of: circuit) { _, new in recompute(new) }
    }

    private func recompute(_ doc: CircuitDocument) {
        issues = DRC.check(doc)
        unrouted = Ratsnest.missingEdges(doc)
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
    /// Assembly-mode docs don't produce a single plate stack — every
    /// export path (STL save, Bambu, Flow Simulator) currently emits one
    /// flattened doc's CAD output and would silently lose the multi-board
    /// shape. Gate the whole menu off while in assembly mode and surface
    /// a tooltip so the user knows why.
    let isAssembly: Bool
    let onSaveSTL: () -> Void
    let onExportBambu: () -> Void
    let onOpenBambu: () -> Void
    let onOpenBambuWithModifier: () -> Void
    let onOpenBambuWithVoidModifier: () -> Void
    let onOpenFlow: () -> Void

    var body: some View {
        Menu {
            Button("Save STL file…", action: onSaveSTL)
            Button("Export for Bambu Studio…", action: onExportBambu)
            Divider()
            Button("Open in Bambu Studio", action: onOpenBambu)
                .disabled(!bambuStudioInstalled)
            // Opens model + modifier together so Bambu offers "load as one
            // object" — remember to switch the _modifier part to a Modifier,
            // or it prints as solid.
            Button("Open in Bambu Studio (with Modifier)", action: onOpenBambuWithModifier)
                .disabled(!bambuStudioInstalled)
            // The inverted pairing: the global preset keeps the pneumatics,
            // the modifier claims the voids (assign it LOW infill in Bambu).
            Button("Open in Bambu Studio (Void Modifier)", action: onOpenBambuWithVoidModifier)
                .disabled(!bambuStudioInstalled)
            Button("Open in Flow Simulator", action: onOpenFlow)
                .disabled(!flowSimulatorInstalled)
        } label: {
            Label(previewDirty ? "Build & Export…" : "Export…",
                  systemImage: "square.and.arrow.up")
        }
        .disabled(isBuilding || isAssembly)
        .help(isAssembly
              ? "Export is unavailable in assembly mode (no single plate stack to build)."
              : "")
    }
}
