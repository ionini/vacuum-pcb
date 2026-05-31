import SwiftUI
import UniformTypeIdentifiers

/// Top-level content of the Physical tab: parking lot on the left, canvas
/// taking the rest. Tool controls live in the window toolbar; document
/// properties (board size, layer counts) live in the inspector.
struct PhysicalView: View {
    @Binding var document: VPCBDocument
    /// Lifted to DocumentView so the sidebar's DRC list can drive
    /// highlight-on-click.
    @Binding var selection: PhysicalSelection
    /// Lifted to DocumentView so the right-hand inspector can read the
    /// in-progress routing state and offer a "Cancel" button (the iPad
    /// stand-in for Escape, which has no key without an external keyboard).
    @Binding var routingState: RoutingState
    /// Transient ping marker for the DRC focus-on-click affordance. Owned
    /// by DocumentView (it's also the one that schedules the auto-clear);
    /// we pass it through to the canvas overlay.
    @Binding var issueFocus: DRC.Focus?
    /// Threaded down so this view can plant the Inspector toolbar toggle as
    /// the rightmost toolbar item.
    @Binding var showInspector: Bool
    /// Passed in from DocumentView so the Export menu can sit immediately
    /// before the Inspector toggle on the trailing edge.
    let exportMenu: ExportMenuButton

    @State private var visible: LayerVisibility = .both
    /// Bottom-to-top paint order of the channel layers. The visibility pills
    /// are drag-reorderable and rewrite this array; the canvas paints layers
    /// in this order so the last entry stacks on top (drag B1 to the right
    /// end to see it above the rest). Reconciled against `allLayers` whenever
    /// the plate layer counts change so added layers appear and removed ones
    /// drop out without disturbing the user's chosen ordering.
    @State private var layerOrder: [Layer] = []
    @State private var routingLayer: Layer = .top
    @State private var routingError: String?
    @State private var showRatsnest: Bool = true
    @State private var showPressureMap: Bool = false
    @State private var pressureSigma: Double = 10.0
    @State private var pressurePopover: Bool = false
    /// Sticky-mode equivalent of holding Cmd while dragging a placement on
    /// macOS — when on, the routes attached to a dragged placement's pins
    /// rubber-band along with it. Lives here so it persists between drags
    /// (the modifier-key version only applies if Cmd is held *at drag
    /// start*, which iPad has no analogue for).
    @State private var dragWithRoutes: Bool = false

    var body: some View {
        // The parking lot now lives in the right-hand inspector (along
        // with board / layer-count controls), so the detail area is just
        // the canvas.
        PhysicalCanvasView(
            document: $document,
            selection: $selection,
            routingState: $routingState,
            visible: $visible,
            layerOrder: orderedLayers,
            routingLayer: $routingLayer,
            routingError: $routingError,
            showRatsnest: showRatsnest,
            showPressureMap: showPressureMap,
            pressureSigma: pressureSigma,
            dragWithRoutes: dragWithRoutes,
            issueFocus: issueFocus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolbar { physicalToolbar }
        .onChange(of: routingLayer) { _, newLayer in
            // If we're mid-route, update the layer of the in-progress
            // polyline so the user sees the change immediately.
            if case let .routing(netId, wps, _, startsAtVia) = routingState {
                routingState = .routing(netId: netId, waypoints: wps, layer: newLayer,
                                        startsAtVia: startsAtVia)
            }
        }
        .onAppear { reconcileLayerOrder() }
        .onChange(of: document.circuit.physical.topLayers) { _, _ in
            ensureRoutingLayerValid()
            reconcileLayerOrder()
        }
        .onChange(of: document.circuit.physical.bottomLayers) { _, _ in
            ensureRoutingLayerValid()
            reconcileLayerOrder()
        }
    }

    @ToolbarContentBuilder private var physicalToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) {
            Picker("Plates", selection: $visible) {
                Text("All").tag(LayerVisibility.both)
                Text("Top").tag(LayerVisibility.topOnly)
                Text("Bottom").tag(LayerVisibility.bottomOnly)
                Text("Sheet").tag(LayerVisibility.siliconeSheet)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 220)
        }
        // The per-layer pills toggle into `.explicit`, which would
        // immediately leave silicone-sheet mode — hide them while that
        // mode is active so the toolbar reads cleanly.
        if !visible.isSiliconeSheet {
            ToolbarItem(placement: .automatic) {
                LayerVisibilityPills(layers: orderedLayers, visible: $visible,
                                     order: $layerOrder)
            }
        }
        ToolbarItem(placement: .automatic) {
            Picker("Route", selection: $routingLayer) {
                ForEach(allLayers, id: \.self) { layer in
                    Text("Route \(layer.uiLabel)").tag(layer)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(minWidth: 110)
        }
        ToolbarItem(placement: .automatic) {
            Toggle(isOn: $showRatsnest) {
                Label("Net Hints", systemImage: "point.3.connected.trianglepath.dotted")
            }
            .toggleStyle(.button)
            .help("Show dashed hint lines between pins on the same net that aren't routed yet")
        }
        ToolbarItem(placement: .automatic) {
            // Sticky equivalent of Cmd-drag on macOS. With this on, every
            // placement drag carries along the route waypoints attached
            // to that placement's pins — handy on iPad where there's no
            // modifier key to gate the rubber-band per drag.
            Toggle(isOn: $dragWithRoutes) {
                Label("Drag with routes", systemImage: "link")
            }
            .toggleStyle(.button)
            .help("Drag a placement to also drag the routes attached to its pins")
        }
        ToolbarItem(placement: .automatic) {
            // Single toolbar control hosts both the on/off toggle and the σ
            // slider — the button shows enabled state at a glance, the
            // popover opens the slider when the user wants to tune the
            // spread. Plain click toggles the map; long-press / right-click
            // would be nicer here but SwiftUI's Button doesn't expose a
            // primary+secondary action cleanly, so we use a Menu fallback:
            // a click opens the popover; the toggle inside is the on switch.
            Button {
                pressurePopover.toggle()
            } label: {
                Label("Pressure Map",
                      systemImage: showPressureMap
                          ? "thermometer.sun.fill"
                          : "thermometer.medium")
            }
            .help("Pressure uniformity heatmap from screw placement")
            .foregroundStyle(showPressureMap ? Color.accentColor : Color.primary)
            .popover(isPresented: $pressurePopover, arrowEdge: .bottom) {
                PressureHeatmapControls(
                    enabled: $showPressureMap,
                    sigma: $pressureSigma
                )
            }
        }
        ToolbarItem(placement: .automatic) {
            Button(action: addScrew) {
                Label("Add Screw", systemImage: "circle.grid.cross")
            }
            .help("Add an M2 screw hole at the centre of the board")
        }
        // Export and Inspector are declared here (in the leaf view) so they
        // render to the right of the parent's toolbar items, with Export
        // immediately to Inspector's left.
        ToolbarItem(placement: .primaryAction) { exportMenu }
        ToolbarItem(placement: .primaryAction) {
            InspectorToggleButton(showInspector: $showInspector)
        }
    }

    /// All layers currently configured on the board, in T0…Tn, B0…Bm order.
    var allLayers: [Layer] {
        document.circuit.physical.layers(in: .top) +
        document.circuit.physical.layers(in: .bottom)
    }

    /// The configured layers in the user's chosen paint order. Falls back to
    /// `allLayers` for any layer not yet recorded in `layerOrder` (e.g. on
    /// the very first render before `reconcileLayerOrder` runs), so the pills
    /// and canvas always have a complete, deterministic sequence to draw.
    var orderedLayers: [Layer] {
        let all = allLayers
        var result = layerOrder.filter { all.contains($0) }
        for layer in all where !result.contains(layer) { result.append(layer) }
        return result
    }

    /// Persist the reconciled paint order back into state after a layer-count
    /// change so the stored array tracks the configured layers — kept layers
    /// hold their position, new ones append in default order, removed ones
    /// drop out. A no-op write is skipped to avoid a redundant invalidation.
    private func reconcileLayerOrder() {
        let next = orderedLayers
        if next != layerOrder { layerOrder = next }
    }

    /// If the routing layer dropdown was pointing at e.g. T1 and the user
    /// just decremented topLayers to 1, snap back to T0 so we don't try to
    /// route on a layer that no longer exists.
    private func ensureRoutingLayerValid() {
        let valid = allLayers
        if !valid.contains(routingLayer), let fallback = valid.first {
            routingLayer = fallback
        }
    }

    /// Drops every unplaced component onto the board, preserving its
    /// schematic-side relative position. We compute the bounding box of the
    /// Creates a new screw component + placement at the centre of the board
    /// and selects it. The user drags it from there. Screws have no pins,
    /// don't participate in the netlist, and are filtered out of the
    /// schematic canvas — they exist only on the physical view.
    private func addScrew() {
        let label = document.circuit.logic.nextLabel(for: .screw)
        let id = UUID()
        document.circuit.logic.components.append(
            Component(id: id, kind: .screw, label: label)
        )
        let outline = document.circuit.physical.boardOutline
        let centre = Point(
            x: outline.origin.x + outline.size.width / 2,
            y: outline.origin.y + outline.size.height / 2
        )
        document.circuit.physical.placements.append(
            Placement(componentId: id, position: centre, rotation: .r0, layer: .top, depth: 0)
        )
        selection = .placement(id)
    }

}

/// Right-hand inspector content for the Physical tab. Hosts the board
/// outline editor and the per-plate layer-count steppers — document
/// properties that aren't transient enough for the toolbar. The
/// confirmation alert for layer removal also lives here, anchored to
/// this view so it appears when the user drives the destructive action.
struct PhysicalInspector: View {
    @Binding var document: VPCBDocument
    /// Read by the contextual section at the top so the inspector mirrors
    /// the canvas's current selection / routing state. Same bindings the
    /// canvas itself writes through.
    @Binding var selection: PhysicalSelection
    @Binding var routingState: RoutingState

    @State private var pendingLayerRemoval: PendingLayerRemoval?
    /// True while a `minimize()` run is in flight, so the button shows a
    /// spinner and stays disabled.
    @State private var isMinimizing = false
    /// Diagnostics from the most recent minimize run, shown under the button
    /// (iterations, area saved, DRC). Nil until the user runs Minimize once.
    @State private var minimizeStats: Minimizer.Stats?
    @FocusState private var boardFieldFocused: BoardField?

    private enum BoardField: Hashable { case width, height }

    var body: some View {
        VStack(spacing: 0) {
            PhysicalContextSection(
                document: $document,
                selection: $selection,
                routingState: $routingState
            )
            // SwiftUI's grouped `Form` reports no usable intrinsic vertical
            // size on iPadOS — it's backed by `UITableView`, which only
            // sizes itself when given a fixed-height container — so the
            // previous `.fixedSize(horizontal: false, vertical: true)`
            // collapsed the whole panel on iPad. A plain VStack with
            // section headers renders identically on both platforms and
            // lets the ScrollView host scrolling when the column is tight.
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    sectionGroup("Board") {
                        HStack(spacing: 6) {
                            TextField("Width", value: boardSizeBinding(\.width),
                                      format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .focused($boardFieldFocused, equals: .width)
                            Text("×").foregroundStyle(.secondary)
                            TextField("Height", value: boardSizeBinding(\.height),
                                      format: .number.precision(.fractionLength(0...2)))
                                .textFieldStyle(.roundedBorder)
                                .multilineTextAlignment(.trailing)
                                .focused($boardFieldFocused, equals: .height)
                            Text("mm").foregroundStyle(.tertiary)
                        }
                        // Pressing Return in either field clears the focus so
                        // the canvas gets keyboard events back (otherwise
                        // R/F/V/0..9 all type into the still-focused field).
                        .onSubmit { boardFieldFocused = nil }
                    }
                    sectionGroup("Channel Layers") {
                        layerStepper(label: "Top plate", plate: .top)
                        layerStepper(label: "Bottom plate", plate: .bottom)
                    }
                    Divider()
                    // Parking lot used to be the leading column of the
                    // Physical tab; it lives here in the inspector now so
                    // the canvas can claim the full detail area.
                    ParkingLotView(
                        document: document.circuit,
                        providerForComponent: { id in
                            NSItemProvider(object: id.uuidString as NSString)
                        },
                        onPlaceAll: placeAllUnplaced,
                        onMinimize: minimize,
                        isMinimizing: isMinimizing,
                        minimizeStats: minimizeStats
                    )
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .alert(item: $pendingLayerRemoval) { removal in
            let layerList = removal.removedLayers.map(\.uiLabel).joined(separator: ", ")
            let routeCount = removal.segmentsToRemove.count
            let viaCount = removal.viasToRemove
            let resistorCount = removal.resistorsToMigrate.count
            var lines: [String] = []
            if routeCount > 0 {
                lines.append("\(routeCount) route segment\(routeCount == 1 ? "" : "s") and \(viaCount) via waypoint\(viaCount == 1 ? "" : "s") will be deleted.")
            }
            if resistorCount > 0 {
                lines.append("\(resistorCount) resistor\(resistorCount == 1 ? "" : "s") will be migrated back to depth 0.")
            }
            return Alert(
                title: Text("Remove layer\(removal.removedLayers.count == 1 ? "" : "s") \(layerList)?"),
                message: Text(lines.joined(separator: " ")),
                primaryButton: .destructive(Text("Remove")) {
                    performPendingLayerRemoval(removal)
                },
                secondaryButton: .cancel()
            )
        }
    }

    /// Header + content vertical block, used in place of `Form` /
    /// `Section` so the inspector renders identically on both platforms
    /// (grouped Form collapses to zero height on iPad — see the comment
    /// in `body`).
    @ViewBuilder
    private func sectionGroup<C: View>(
        _ title: String,
        @ViewBuilder _ content: () -> C
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
            content()
        }
    }

    @ViewBuilder
    private func layerStepper(label: String, plate: Plate) -> some View {
        let current = document.circuit.physical.layerCount(for: plate)
        HStack(spacing: 8) {
            Text(label)
            Spacer()
            // The count Text sits outside the Stepper so it stays visible —
            // putting it inside the Stepper's label closure relies on
            // SwiftUI's macOS Stepper rendering its label, which it
            // doesn't do when squeezed into an inspector row.
            Text("\(current)")
                .monospacedDigit()
                .frame(minWidth: 20, alignment: .trailing)
            Stepper("", value: Binding(
                get: { current },
                set: { applyLayerCount($0, on: plate) }
            ), in: 1...4)
            .labelsHidden()
        }
    }

    private func boardSizeBinding(_ keyPath: WritableKeyPath<Size, Double>) -> Binding<Double> {
        Binding(
            get: { document.circuit.physical.boardOutline.size[keyPath: keyPath] },
            set: { document.circuit.physical.boardOutline.size[keyPath: keyPath] = max(1, $0) }
        )
    }

    /// Increment is a no-op except to grow the count. Decrement may evict
    /// route segments / vias on the removed layer; we collect those into a
    /// confirmation summary before applying.
    private func applyLayerCount(_ newCount: Int, on plate: Plate) {
        let clamped = max(1, min(4, newCount))
        let current = document.circuit.physical.layerCount(for: plate)
        guard clamped != current else { return }
        if clamped > current {
            setLayerCount(clamped, on: plate)
            return
        }
        let removedLayers: [Layer] = (clamped..<current).map { Layer(plate: plate, depth: $0) }
        let removedSet = Set(removedLayers)
        var segsToRemove: [(Int, Int)] = []
        var viaCount = 0
        for (routeIdx, route) in document.circuit.physical.routes.enumerated() {
            for (segIdx, seg) in route.segments.enumerated() where removedSet.contains(seg.layer) {
                segsToRemove.append((routeIdx, segIdx))
                viaCount += seg.waypoints.filter { $0.kind == .via }.count
            }
        }
        // Placements pinned to a removed depth — resistors and edge-bore
        // components (ports/vents/vacuum sources) can both sit at depth>0,
        // so all four kinds need migrating back to depth 0 when their
        // layer disappears. Transistors are already pinned to depth 0.
        var resistorMigrations: [UUID] = []
        for placement in document.circuit.physical.placements
        where placement.layer == plate && removedSet.contains(Layer(plate: plate, depth: placement.depth)) {
            if let component = document.circuit.logic.components.first(where: { $0.id == placement.componentId }) {
                switch component.kind {
                case .resistor, .port, .vacuumSource, .atmVent:
                    resistorMigrations.append(placement.componentId)
                default:
                    break
                }
            }
        }
        if segsToRemove.isEmpty && resistorMigrations.isEmpty {
            setLayerCount(clamped, on: plate)
            return
        }
        pendingLayerRemoval = PendingLayerRemoval(
            plate: plate, newCount: clamped, removedLayers: removedLayers,
            segmentsToRemove: segsToRemove, viasToRemove: viaCount,
            resistorsToMigrate: resistorMigrations
        )
    }

    private func setLayerCount(_ count: Int, on plate: Plate) {
        switch plate {
        case .top:    document.circuit.physical.topLayers = count
        case .bottom: document.circuit.physical.bottomLayers = count
        }
    }

    private func performPendingLayerRemoval(_ removal: PendingLayerRemoval) {
        let removedSet = Set(removal.removedLayers)
        for routeIdx in document.circuit.physical.routes.indices {
            document.circuit.physical.routes[routeIdx].segments
                .removeAll { removedSet.contains($0.layer) }
        }
        document.circuit.physical.routes.removeAll { $0.segments.isEmpty }
        for componentId in removal.resistorsToMigrate {
            if let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == componentId }) {
                document.circuit.physical.placements[i].depth = 0
            }
        }
        setLayerCount(removal.newCount, on: removal.plate)
    }

    private struct PendingLayerRemoval: Identifiable {
        let id = UUID()
        let plate: Plate
        let newCount: Int
        let removedLayers: [Layer]
        let segmentsToRemove: [(routeIdx: Int, segmentIdx: Int)]
        let viasToRemove: Int
        let resistorsToMigrate: [UUID]
    }

    // MARK: - Parking-lot actions

    /// Drops every unplaced component onto the board, preserving its
    /// schematic-side relative position. We compute the bounding box of
    /// the unplaced components' schematic XYs, uniformly scale it to fit
    /// the board outline (less a margin), and translate so the cluster is
    /// centred. Components without a schematic position fall back to the
    /// centroid. Transistors default to the bottom plate, everything else
    /// to top — same convention the parking-lot drop uses.
    private func placeAllUnplaced() {
        let placed = Set(document.circuit.physical.placements.map(\.componentId))
        let unplaced = document.circuit.logic.components.filter { !placed.contains($0.id) }
        guard !unplaced.isEmpty else { return }

        let outline = document.circuit.physical.boardOutline
        let pitch = document.circuit.manufacturing.gridPitch
        let margin: Double = 3
        func snap(_ v: Double) -> Double { (v / pitch).rounded() * pitch }

        var schematicPositions: [UUID: Point] = [:]
        for component in unplaced {
            if let p = document.circuit.schematic.position(for: component.id) {
                schematicPositions[component.id] = p
            }
        }
        let fallback = Point(
            x: outline.origin.x + outline.size.width / 2,
            y: outline.origin.y + outline.size.height / 2
        )
        if schematicPositions.isEmpty {
            for component in unplaced {
                let start = PhysicalActions.startingLayer(for: component, in: document.circuit)
                document.circuit.physical.placements.append(
                    Placement(
                        componentId: component.id,
                        position: Point(x: snap(fallback.x), y: snap(fallback.y)),
                        rotation: .r0, layer: start.plate, depth: start.depth
                    )
                )
            }
            return
        }

        let xs = schematicPositions.values.map(\.x)
        let ys = schematicPositions.values.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        let schWidth = max(1, maxX - minX)
        let schHeight = max(1, maxY - minY)

        let availW = max(pitch, outline.size.width - 2 * margin)
        let availH = max(pitch, outline.size.height - 2 * margin)
        let scale = min(availW / schWidth, availH / schHeight)
        let usedW = schWidth * scale
        let usedH = schHeight * scale
        let offsetX = outline.origin.x + margin + (availW - usedW) / 2
        let offsetY = outline.origin.y + margin + (availH - usedH) / 2

        for component in unplaced {
            let sch = schematicPositions[component.id] ?? fallback
            let pos = Point(
                x: snap((sch.x - minX) * scale + offsetX),
                y: snap((sch.y - minY) * scale + offsetY)
            )
            let start = PhysicalActions.startingLayer(for: component, in: document.circuit)
            document.circuit.physical.placements.append(
                Placement(
                    componentId: component.id,
                    position: pos,
                    rotation: .r0,
                    layer: start.plate,
                    depth: start.depth
                )
            )
        }
    }

    /// Simulated-annealing compaction of the placed-and-routed board. The
    /// pure model layer is main-actor-isolated (the project's default
    /// isolation), so the search runs on the main actor rather than a detached
    /// task — its time budget is kept short for that reason. The leading
    /// `Task.yield()` lets the "Minimizing…" state paint before the compute;
    /// the result is written back in one mutation, so it's a single undo step,
    /// and only `physical` is assigned since the minimiser never touches the
    /// logic graph.
    private func minimize() {
        guard !isMinimizing else { return }
        isMinimizing = true
        Task { @MainActor in
            await Task.yield()
            let result = Minimizer.report(document.circuit)
            // Only the physical projection changes (one undo step); the logic
            // graph is never touched. Always assign so a no-improvement run is
            // a true no-op rather than a redundant mutation.
            if result.stats.adopted {
                document.circuit.physical = result.doc.physical
            }
            minimizeStats = result.stats
            isMinimizing = false
        }
    }
}

/// Contextual action block at the top of the physical inspector. Shows
/// nothing for an empty / canvas-idle state; surfaces Rotate / Flip /
/// Delete when one or more placements are selected; surfaces Delete on
/// route-segment selection; surfaces Cancel while a route is being laid
/// out. Same actions the keyboard shortcuts trigger on macOS — these
/// buttons are the only path on iPad.
struct PhysicalContextSection: View {
    @Binding var document: VPCBDocument
    @Binding var selection: PhysicalSelection
    @Binding var routingState: RoutingState

    var body: some View {
        Group {
            if routingState.inProgress {
                container { routingActions }
            } else if !selection.placements.isEmpty {
                container { placementActions }
            } else if selection.routeSegment != nil {
                container { routeSegmentActions }
            }
        }
    }

    @ViewBuilder
    private func container<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }

    @ViewBuilder private var routingActions: some View {
        Text("Routing")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
        Button {
            routingState = .idle
        } label: {
            Label("Cancel routing", systemImage: "xmark.circle")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
        .controlSize(.regular)
    }

    @ViewBuilder private var placementActions: some View {
        Text(placementHeader)
            .font(.caption.bold())
            .foregroundStyle(.secondary)
        HStack(spacing: 6) {
            Button {
                PhysicalActions.rotate(document: &document, selection: selection)
            } label: {
                Label("Rotate", systemImage: "rotate.right")
                    .frame(maxWidth: .infinity)
            }
            .help("Rotate 90° clockwise (R)")
            Button {
                PhysicalActions.flipLayer(document: &document, selection: selection)
            } label: {
                Label("Flip", systemImage: "arrow.up.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .help("Cycle plate / layer (F)")
        }
        .buttonStyle(.bordered)
        Button(role: .destructive) {
            PhysicalActions.delete(document: &document, selection: &selection)
        } label: {
            Label("Delete", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    @ViewBuilder private var routeSegmentActions: some View {
        Text("Route segment")
            .font(.caption.bold())
            .foregroundStyle(.secondary)
        Button(role: .destructive) {
            PhysicalActions.delete(document: &document, selection: &selection)
        } label: {
            Label("Delete segment", systemImage: "trash")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.bordered)
    }

    private var placementHeader: String {
        let n = selection.placements.count
        return n == 1 ? "Placement" : "\(n) placements"
    }
}

/// Mutations the physical canvas and its inspector both trigger.
///
/// Originally lived as private methods on `PhysicalCanvasView` and were
/// only reachable via keyboard shortcuts (R / F / ⌫). Lifted out so the
/// inspector's contextual action buttons can drive the same code on iPad
/// (where those shortcuts aren't available without an external keyboard).
enum PhysicalActions {
    /// Picks the starting plate + depth for a component being imported from
    /// the parking lot. If the component shares a net with pins that are
    /// already placed, it lands on the layer it connects to — an
    /// outlet/inlet appears on its net-mate's plate + depth, ready to route
    /// — and the user can still move it afterward.
    ///
    /// Falls back to the geometric default when nothing on its nets is
    /// placed yet: bottom for dimple-bearing kinds (transistor, LED) so
    /// their viewing/source features land on the top plate, top otherwise.
    /// Dimple kinds keep that geometric plate regardless of the ratsnest —
    /// flipping them would move the dimple to the wrong side.
    static func startingLayer(
        for component: Component,
        in circuit: CircuitDocument
    ) -> (plate: Plate, depth: Int) {
        let dimpleKinds: Set<ComponentKind> = [.transistor, .led]
        if dimpleKinds.contains(component.kind) { return (.bottom, 0) }

        let fp = component.footprint(circuit.manufacturing, snapshots: circuit.librarySnapshots)

        // Tally the plate + depth each of this component's pins would need so
        // it resolves onto the layer of an already-placed net-mate. One vote
        // per (own pin, placed net-mate) pairing; majority wins, so a
        // single-pin outlet/inlet simply inherits its sole neighbour's layer.
        var plateVotes: [Plate: Int] = [:]
        var depthVotes: [Int: Int] = [:]
        for pin in fp.pins {
            // A pin pinned to an absolute layer (sub-part boundary) can't be
            // steered by placement.layer/depth, so it gets no say.
            guard pin.absoluteLayer == nil else { continue }
            let ownRef = PinRef(componentId: component.id, pinKey: pin.key)
            for net in circuit.logic.nets where net.pins.contains(ownRef) {
                for mate in net.pins where mate.componentId != component.id {
                    guard let placement = circuit.physical.placements
                            .first(where: { $0.componentId == mate.componentId }),
                          let mateComponent = circuit.logic.components
                            .first(where: { $0.id == mate.componentId }),
                          let matePin = mateComponent
                            .footprint(circuit.manufacturing, snapshots: circuit.librarySnapshots)
                            .pin(mate.pinKey)
                    else { continue }
                    let mateLayer = placement.resolvedLayer(of: matePin, on: mateComponent)
                    // The placement plate that lands *this* pin on the mate's plate.
                    let plate = pin.relativeLayer == .opposite ? mateLayer.plate.opposite : mateLayer.plate
                    plateVotes[plate, default: 0] += 1
                    depthVotes[mateLayer.depth, default: 0] += 1
                }
            }
        }

        func winner<T>(_ votes: [T: Int], default fallback: T) -> T {
            votes.max(by: { $0.value < $1.value })?.key ?? fallback
        }
        let plate = winner(plateVotes, default: .top)

        // Depth only matters for kinds whose pin layer inherits placement.depth
        // (resolvedLayer forces depth 0 for the rest), so don't stamp a stray
        // depth onto, say, a sub-part placement.
        let inheritsDepth: Set<ComponentKind> = [.resistor, .port, .vacuumSource, .atmVent]
        let depth = inheritsDepth.contains(component.kind) ? winner(depthVotes, default: 0) : 0

        return (plate, depth)
    }

    /// Rotate every selected placement by 90° around its own anchor. The
    /// multi-select case deliberately rotates each member independently
    /// (not around the selection centroid) because users typically reach
    /// for this to fix orientation on a row of identical parts.
    static func rotate(document: inout VPCBDocument, selection: PhysicalSelection) {
        guard !selection.placements.isEmpty else { return }
        for id in selection.placements {
            guard let i = document.circuit.physical.placements
                .firstIndex(where: { $0.componentId == id })
            else { continue }
            let component = document.circuit.logic.components.first(where: { $0.id == id })
            // Connectors derive rotation from their edge — cycle the edge
            // (and re-derive rotation) instead of rotating in place, so the
            // protrusion stays attached to a perimeter edge.
            if component?.kind == .connector,
               let anchor = document.circuit.physical.placements[i].edgeAnchor {
                let next: Edge
                switch anchor.edge {
                case .south: next = .east
                case .east:  next = .north
                case .north: next = .west
                case .west:  next = .south
                }
                let outline = document.circuit.physical.boardOutline
                let m = document.circuit.manufacturing
                let fp = component!.footprint(m)
                let clearance = fp.exclusionRect.size.height / 2 + m.gridPitch
                let len = (next == .north || next == .south) ? outline.size.width : outline.size.height
                var offset = anchor.offsetAlongEdge
                offset = max(clearance, min(len - clearance, offset))
                let newAnchor = EdgeAnchor(edge: next, offsetAlongEdge: offset)
                document.circuit.physical.placements[i].edgeAnchor = newAnchor
                document.circuit.physical.placements[i].position = newAnchor.worldPosition(in: outline)
                document.circuit.physical.placements[i].rotation = next.outwardRotation
                continue
            }
            let next: Rotation
            switch document.circuit.physical.placements[i].rotation {
            case .r0:   next = .r90
            case .r90:  next = .r180
            case .r180: next = .r270
            case .r270: next = .r0
            }
            document.circuit.physical.placements[i].rotation = next
        }
    }

    /// Snap a connector placement to the nearest plate edge, updating
    /// `edgeAnchor`, `position`, `rotation`, and `layer` (from role).
    /// Shared between the parking-lot drop path and the drag-end path so
    /// connectors behave identically regardless of which entry point
    /// drove the move.
    static func snapConnector(
        in circuit: inout CircuitDocument,
        placementIndex i: Int,
        component: Component,
        world: Point
    ) {
        let outline = circuit.physical.boardOutline
        let m = circuit.manufacturing
        let fp = component.footprint(m)
        // Just `halfRow` — the exclusion rect already bakes in
        // `minWallThickness` at each end of the row (see
        // `connectorFootprint`), so this clearance is exactly the
        // distance from the anchor centre to the outer face of the row.
        // Padding any further would prevent a connector from sitting
        // centred on an edge whose length matches the protrusion length,
        // e.g. a 4-pin connector (37.1 mm at default constants) on a
        // 37 mm board would otherwise snap ~1 mm off-centre.
        let clearance = fp.exclusionRect.size.height / 2
        let anchor = EdgeAnchor.snapping(
            worldPoint: world,
            to: outline,
            minClearance: clearance,
            gridSnap: m.gridPitch
        )
        circuit.physical.placements[i].edgeAnchor = anchor
        circuit.physical.placements[i].position = anchor.worldPosition(in: outline)
        circuit.physical.placements[i].rotation = anchor.edge.outwardRotation
        let role = component.connectorRole ?? .bottomExtend
        circuit.physical.placements[i].layer = role == .bottomExtend ? .bottom : .top
    }

    /// Cycle each selected placement's layer. Pure-hole components
    /// (resistors as tubes; ports / vents / vacuum sources as edge
    /// bores) step through every channel layer the board defines.
    /// Transistors and other dimple-bearing kinds simply flip to the
    /// opposite plate at depth 0 since their geometry is pinned to the
    /// silicone face.
    static func flipLayer(document: inout VPCBDocument, selection: PhysicalSelection) {
        guard !selection.placements.isEmpty else { return }
        let cycle = document.circuit.physical.layers(in: .top)
            + document.circuit.physical.layers(in: .bottom)
        for id in selection.placements {
            guard let i = document.circuit.physical.placements
                .firstIndex(where: { $0.componentId == id })
            else { continue }
            let placement = document.circuit.physical.placements[i]
            let component = document.circuit.logic.components
                .first(where: { $0.id == id })
            let cyclesLayers: Bool = {
                switch component?.kind {
                case .resistor, .port, .vacuumSource, .atmVent: return true
                default: return false
                }
            }()
            if cyclesLayers, !cycle.isEmpty {
                let current = Layer(plate: placement.layer, depth: placement.depth)
                let idx = cycle.firstIndex(of: current) ?? 0
                let next = cycle[(idx + 1) % cycle.count]
                document.circuit.physical.placements[i].layer = next.plate
                document.circuit.physical.placements[i].depth = next.depth
            } else {
                document.circuit.physical.placements[i].layer = placement.layer.opposite
                document.circuit.physical.placements[i].depth = 0
            }
        }
    }

    /// Bulk-delete everything in the selection: placements (the logic-side
    /// component isn't touched — schematic edits delete those), the focused
    /// route segment, and every segment that contains a marquee-selected
    /// waypoint. Selection is cleared to `.none` once done.
    static func delete(document: inout VPCBDocument, selection: inout PhysicalSelection) {
        if !selection.placements.isEmpty {
            for id in selection.placements {
                document.circuit.physical.placements.removeAll { $0.componentId == id }
            }
        }
        var toRemove: [UUID: Set<Int>] = [:]
        for addr in selection.waypoints {
            toRemove[addr.netId, default: []].insert(addr.segmentIndex)
        }
        if let seg = selection.routeSegment {
            toRemove[seg.netId, default: []].insert(seg.segmentIndex)
        }
        for (netId, segIndices) in toRemove {
            guard let rIdx = document.circuit.physical.routes
                .firstIndex(where: { $0.netId == netId })
            else { continue }
            // Descending so earlier removals don't shift later indices.
            for sIdx in segIndices.sorted(by: >) {
                if sIdx < document.circuit.physical.routes[rIdx].segments.count {
                    document.circuit.physical.routes[rIdx].segments.remove(at: sIdx)
                }
            }
            if document.circuit.physical.routes[rIdx].segments.isEmpty {
                document.circuit.physical.routes.remove(at: rIdx)
            }
        }
        selection = .none
    }
}
