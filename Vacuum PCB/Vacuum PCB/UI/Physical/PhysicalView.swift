import SwiftUI
import UniformTypeIdentifiers

/// Top-level content of the Physical tab: parking lot on the left, canvas in
/// the middle, layer/tool strip across the bottom of the canvas area.
struct PhysicalView: View {
    @Binding var document: VPCBDocument
    /// Lifted to DocumentView so the sidebar's DRC list can drive
    /// highlight-on-click.
    @Binding var selection: PhysicalSelection

    @State private var routingState: RoutingState = .idle
    @State private var visible: LayerVisibility = .both
    @State private var routingLayer: Layer = .top
    @State private var routingError: String?
    @State private var showRatsnest: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            ParkingLotView(
                document: document.circuit,
                providerForComponent: { id in
                    NSItemProvider(object: id.uuidString as NSString)
                },
                onPlaceAll: placeAllUnplaced,
                onAutoPlace: autoPlace,
                onAutoRoute: autoRoute
            )
            Divider()
            VStack(spacing: 0) {
                PhysicalCanvasView(
                    document: $document,
                    selection: $selection,
                    routingState: $routingState,
                    visible: $visible,
                    routingLayer: $routingLayer,
                    routingError: $routingError,
                    showRatsnest: showRatsnest
                )
                Divider()
                bottomStrip
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

    private var bottomStrip: some View {
        HStack(spacing: 12) {
            // Plate-level visibility shortcut (legacy "All / Top / Bottom").
            // The per-layer multi-select pills appear after this, generated
            // from the document's actual layer counts.
            Picker("Visible plates", selection: $visible) {
                Text("All").tag(LayerVisibility.both)
                Text("Top").tag(LayerVisibility.topOnly)
                Text("Bottom").tag(LayerVisibility.bottomOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 180)
            .labelsHidden()

            perLayerVisibilityPills

            Divider().frame(height: 18)

            Picker("Routing layer", selection: $routingLayer) {
                ForEach(allLayers, id: \.self) { layer in
                    Text("Route \(layer.uiLabel)").tag(layer)
                }
            }
            .pickerStyle(.menu)
            .frame(minWidth: 110)
            .labelsHidden()
            .onChange(of: routingLayer) { _, newLayer in
                // If we're mid-route, update the layer of the in-progress polyline
                // so the user sees the change immediately.
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

            Divider().frame(height: 18)

            Toggle("Ratsnest", isOn: $showRatsnest)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)

            Divider().frame(height: 18)

            boardSizeEditor

            Divider().frame(height: 18)

            layerCountEditor

            Divider().frame(height: 18)

            Button(action: addScrew) {
                Label("Screw", systemImage: "circle.grid.cross")
                    .font(.caption)
            }
            .controlSize(.small)
            .help("Add an M2 screw hole at the centre of the board (drag to position)")

            Spacer()

            if let routingError {
                Text(routingError)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            } else {
                statusText
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .frame(minHeight: 44)
    }

    /// All layers currently configured on the board, in T0…Tn, B0…Bm order.
    private var allLayers: [Layer] {
        document.circuit.physical.layers(in: .top) +
        document.circuit.physical.layers(in: .bottom)
    }

    /// Per-layer chips for explicit multi-select. Each chip shows "T0",
    /// "B1", etc. and toggles that single layer in/out of the visible set.
    /// Multi-layer plates are the whole reason this row exists — with two
    /// channel layers on the bottom plate, the user wants to inspect just B0
    /// or B0+T0 etc. without losing context.
    private var perLayerVisibilityPills: some View {
        HStack(spacing: 4) {
            ForEach(allLayers, id: \.self) { layer in
                let on = visible.contains(layer)
                Button(action: { toggleLayer(layer) }) {
                    Text(layer.uiLabel)
                        .font(.caption.monospacedDigit())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(on ? LayerPalette.color(for: layer).opacity(0.85)
                                       : Color.secondary.opacity(0.12))
                        .foregroundStyle(on ? .white : .secondary)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    /// Promote whatever `visible` currently is to an explicit set, with the
    /// tapped layer flipped. The "All / Top / Bottom" picker stays in sync
    /// by reading `visible` directly; tapping a chip moves us into
    /// `.explicit` mode unconditionally.
    private func toggleLayer(_ layer: Layer) {
        var set = Set(allLayers.filter { visible.contains($0) })
        if set.contains(layer) {
            set.remove(layer)
        } else {
            set.insert(layer)
        }
        visible = .explicit(set)
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

    /// Stepper pair for adjusting the per-plate channel-layer count. Removing
    /// a layer that has content (route segments or via twins on that layer)
    /// pops a confirmation dialog (handled in `applyLayerCount`).
    private var layerCountEditor: some View {
        HStack(spacing: 8) {
            layerStepper(label: "Top L", plate: .top)
            layerStepper(label: "Bot L", plate: .bottom)
        }
    }

    @ViewBuilder
    private func layerStepper(label: String, plate: Plate) -> some View {
        let current = document.circuit.physical.layerCount(for: plate)
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Stepper(value: Binding(
                get: { current },
                set: { applyLayerCount($0, on: plate) }
            ), in: 1...4) {
                Text("\(current)")
                    .font(.caption.monospacedDigit())
                    .frame(width: 16)
            }
            .labelsHidden()
            .controlSize(.mini)
        }
    }

    /// Increment is a no-op except to grow the count. Decrement may evict
    /// route segments / vias on the removed layer; we collect those into a
    /// confirmation summary before applying. The confirmation alert is
    /// surfaced via the @State below; once confirmed, segments/vias on the
    /// removed layer are dropped and the count is updated.
    @State private var pendingLayerRemoval: PendingLayerRemoval?

    private struct PendingLayerRemoval: Identifiable {
        let id = UUID()
        let plate: Plate
        let newCount: Int
        let removedLayers: [Layer]
        let segmentsToRemove: [(routeIdx: Int, segmentIdx: Int)]
        let viasToRemove: Int
        /// Resistor placements stranded on a removed depth — they get
        /// migrated back to depth 0 (same plate) on confirm, since pure-tube
        /// components can sit anywhere but a non-existent layer is invalid.
        let resistorsToMigrate: [UUID]
    }

    private func applyLayerCount(_ newCount: Int, on plate: Plate) {
        let clamped = max(1, min(4, newCount))
        let current = document.circuit.physical.layerCount(for: plate)
        guard clamped != current else { return }
        if clamped > current {
            // Pure additive: nothing to evict.
            setLayerCount(clamped, on: plate)
            return
        }
        // Removing layers: identify everything that lives on layers about to
        // disappear so the user can confirm in one step.
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
        where placement.layer == plate && removedSet.contains(Layer(plate: plate, depth: placement.depth))
        {
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
        ensureRoutingLayerValid()
    }

    private func performPendingLayerRemoval(_ removal: PendingLayerRemoval) {
        let removedSet = Set(removal.removedLayers)
        for routeIdx in document.circuit.physical.routes.indices {
            document.circuit.physical.routes[routeIdx].segments
                .removeAll { removedSet.contains($0.layer) }
        }
        // Drop now-empty routes so they don't linger.
        document.circuit.physical.routes.removeAll { $0.segments.isEmpty }
        // Migrate stranded resistors back to depth 0 on the same plate.
        for componentId in removal.resistorsToMigrate {
            if let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == componentId }) {
                document.circuit.physical.placements[i].depth = 0
            }
        }
        setLayerCount(removal.newCount, on: removal.plate)
    }

    /// Compact "Board: W × H mm" widget for the physical-tab bottom strip.
    /// Full manufacturing settings live on the 3D preview sidebar; here we
    /// only surface the board outline since it directly affects the canvas
    /// the user is editing.
    private var boardSizeEditor: some View {
        HStack(spacing: 4) {
            Text("Board").font(.caption).foregroundStyle(.secondary)
            TextField("", value: boardSizeBinding(\.width),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($boardFieldFocused, equals: .width)
            Text("×").font(.caption).foregroundStyle(.secondary)
            TextField("", value: boardSizeBinding(\.height),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
                .focused($boardFieldFocused, equals: .height)
            Text("mm").font(.caption2).foregroundStyle(.tertiary)
        }
        // Pressing Return in either field clears the focus so the canvas
        // gets keyboard events back (otherwise R/F/V/0..9 all type into
        // the still-focused field).
        .onSubmit { boardFieldFocused = nil }
    }

    @FocusState private var boardFieldFocused: BoardField?

    private enum BoardField: Hashable { case width, height }

    /// Drops every unplaced component onto the board, preserving its
    /// schematic-side relative position. We compute the bounding box of the
    /// unplaced components' schematic XYs, uniformly scale it to fit the
    /// board outline (less a margin), and translate so the cluster is
    /// centered. The result is "your schematic, projected onto the plate" —
    /// rough enough to need hand-tuning, close enough that the user can
    /// recognise their layout. Components without a schematic position
    /// (shouldn't happen in practice) fall back to the centroid.
    ///
    /// Transistors default to the bottom plate, everything else to top —
    /// same convention as the parking-lot drop.
    private func placeAllUnplaced() {
        let placed = Set(document.circuit.physical.placements.map(\.componentId))
        let unplaced = document.circuit.logic.components.filter { !placed.contains($0.id) }
        guard !unplaced.isEmpty else { return }

        let outline = document.circuit.physical.boardOutline
        let pitch = document.circuit.manufacturing.gridPitch
        let margin: Double = 3
        func snap(_ v: Double) -> Double { (v / pitch).rounded() * pitch }

        // Bounding box of schematic positions. Coords are SwiftUI points;
        // we just need their relative layout, the scale gets handled by the
        // fit step.
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
            // No schematic info → just drop them all at the centroid.
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
        // Centre the scaled cluster inside the usable area.
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

    /// One-shot force-directed re-layout of every already-placed component.
    /// Components are moved in place — relative ordering is preserved as a
    /// starting point — so existing routes (mostly) survive, but the user
    /// will typically need to re-route. Best run on a fresh "Place all"
    /// before any routing.
    private func autoPlace() {
        let result = AutoPlacer.place(document.circuit)
        for entry in result {
            guard let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == entry.componentId })
            else { continue }
            document.circuit.physical.placements[i].position = entry.position
        }
    }

    /// One-shot auto-router. Appends segments for any net pair on the same
    /// layer that an A* path can find on the current occupancy. Existing
    /// routes are preserved.
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

    private func boardSizeBinding(_ keyPath: WritableKeyPath<Size, Double>) -> Binding<Double> {
        Binding(
            get: { document.circuit.physical.boardOutline.size[keyPath: keyPath] },
            set: { document.circuit.physical.boardOutline.size[keyPath: keyPath] = max(1, $0) }
        )
    }

    private var statusText: Text {
        switch routingState {
        case .idle:
            if selection.isEmpty {
                return Text("Drag from parking lot to place. Marquee selects multiple. Click pin to start routing. R rotate · F flip layer · ⌫ delete.")
            }
            if selection.routeSegment != nil {
                return Text("Route segment selected. ⌫ to delete. Right-click an interior waypoint to remove it.")
            }
            if let only = selection.singlePlacement {
                let label = document.circuit.logic.components.first(where: { $0.id == only })?.label ?? "?"
                return Text("Placement \(label) selected. ⌘-drag to move with routes · R rotate · F flip layer · ⌫ delete.")
            }
            return Text("\(selection.placements.count) placements selected. ⌘-drag to move with routes · R rotate · F flip layer · ⌫ delete.")
        case .routing(let netId, let wps, let layer, _):
            let netLabel = document.circuit.logic.nets.first(where: { $0.id == netId })?.label ?? "?"
            return Text("Routing net \(netLabel) on \(layer.uiLabel) · \(wps.count) waypoints · V via \(layer.plate.opposite.uiPrefix)0 · digit N via \(layer.plate.uiPrefix)N · click pin to commit · ESC cancel.")
        }
    }
}
