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
    /// Threaded down so this view can plant the Inspector toolbar toggle as
    /// the rightmost toolbar item.
    @Binding var showInspector: Bool
    /// Passed in from DocumentView so the Export menu can sit immediately
    /// before the Inspector toggle on the trailing edge.
    let exportMenu: ExportMenuButton

    @State private var routingState: RoutingState = .idle
    @State private var visible: LayerVisibility = .both
    @State private var routingLayer: Layer = .top
    @State private var routingError: String?
    @State private var showRatsnest: Bool = true

    var body: some View {
        // The parking lot now lives in the right-hand inspector (along
        // with board / layer-count controls), so the detail area is just
        // the canvas.
        PhysicalCanvasView(
            document: $document,
            selection: $selection,
            routingState: $routingState,
            visible: $visible,
            routingLayer: $routingLayer,
            routingError: $routingError,
            showRatsnest: showRatsnest
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
        .onChange(of: document.circuit.physical.topLayers) { _, _ in
            ensureRoutingLayerValid()
        }
        .onChange(of: document.circuit.physical.bottomLayers) { _, _ in
            ensureRoutingLayerValid()
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
                LayerVisibilityPills(layers: allLayers, visible: $visible)
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

    @State private var pendingLayerRemoval: PendingLayerRemoval?
    @FocusState private var boardFieldFocused: BoardField?

    private enum BoardField: Hashable { case width, height }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Board") {
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
                Section("Channel Layers") {
                    layerStepper(label: "Top plate", plate: .top)
                    layerStepper(label: "Bottom plate", plate: .bottom)
                }
            }
            .formStyle(.grouped)
            .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Parking lot used to be the leading column of the Physical
            // tab; it lives here in the inspector now so the canvas can
            // claim the full detail area.
            ParkingLotView(
                document: document.circuit,
                providerForComponent: { id in
                    NSItemProvider(object: id.uuidString as NSString)
                },
                onPlaceAll: placeAllUnplaced,
                onAutoPlace: autoPlace,
                onAutoRoute: autoRoute
            )
            .padding(.vertical, 6)
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
                let defaultLayer: Plate = (component.kind == .transistor) ? .bottom : .top
                document.circuit.physical.placements.append(
                    Placement(
                        componentId: component.id,
                        position: Point(x: snap(fallback.x), y: snap(fallback.y)),
                        rotation: .r0, layer: defaultLayer
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
            let defaultLayer: Plate = (component.kind == .transistor) ? .bottom : .top
            document.circuit.physical.placements.append(
                Placement(
                    componentId: component.id,
                    position: pos,
                    rotation: .r0,
                    layer: defaultLayer
                )
            )
        }
    }

    /// Force-directed re-layout of every already-placed component.
    /// Components move in place — relative ordering is preserved — so
    /// existing routes mostly survive, but the user will typically need
    /// to re-route. Best run on a fresh "Place all" before any routing.
    private func autoPlace() {
        let result = AutoPlacer.place(document.circuit)
        for entry in result {
            guard let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == entry.componentId })
            else { continue }
            document.circuit.physical.placements[i].position = entry.position
        }
    }

    /// One-shot auto-router. Appends segments for any net pair on the
    /// same layer that an A* path can find on the current occupancy.
    /// Existing routes are preserved.
    private func autoRoute() {
        let plan = AutoRouter.plan(document.circuit)
        for entry in plan {
            if let i = document.circuit.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                document.circuit.physical.routes[i].segments.append(entry.segment)
            } else {
                document.circuit.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }
}
