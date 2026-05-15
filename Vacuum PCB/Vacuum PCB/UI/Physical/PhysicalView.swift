import SwiftUI
import UniformTypeIdentifiers

/// Top-level content of the Physical tab: parking lot on the left, canvas in
/// the middle, layer/tool strip across the bottom of the canvas area.
struct PhysicalView: View {
    @Binding var document: VPCBDocument

    @State private var selection: PhysicalSelection = .none
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
    }

    private var bottomStrip: some View {
        HStack(spacing: 12) {
            Picker("Visible layers", selection: $visible) {
                Text("Both").tag(LayerVisibility.both)
                Text("Top").tag(LayerVisibility.topOnly)
                Text("Bottom").tag(LayerVisibility.bottomOnly)
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .labelsHidden()

            Divider().frame(height: 18)

            Picker("Routing layer", selection: $routingLayer) {
                Text("Route ▲ top").tag(Layer.top)
                Text("Route ▼ bottom").tag(Layer.bottom)
            }
            .pickerStyle(.segmented)
            .frame(width: 240)
            .labelsHidden()
            .onChange(of: routingLayer) { _, newLayer in
                // If we're mid-route, update the layer of the in-progress polyline
                // so the user sees the change immediately.
                if case let .routing(netId, wps, _, startsAtVia) = routingState {
                    routingState = .routing(netId: netId, waypoints: wps, layer: newLayer,
                                            startsAtVia: startsAtVia)
                }
            }

            Divider().frame(height: 18)

            Toggle("Ratsnest", isOn: $showRatsnest)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(.caption)

            Divider().frame(height: 18)

            boardSizeEditor

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
            Text("×").font(.caption).foregroundStyle(.secondary)
            TextField("", value: boardSizeBinding(\.height),
                      format: .number.precision(.fractionLength(0...2)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 48)
            Text("mm").font(.caption2).foregroundStyle(.tertiary)
        }
    }

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
                let defaultLayer: Layer = (component.kind == .transistor) ? .bottom : .top
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
            let defaultLayer: Layer = (component.kind == .transistor) ? .bottom : .top
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
            return Text("Routing net \(netLabel) on \(layer == .top ? "top" : "bottom") · \(wps.count) waypoints · V to drop a via, click a pin on this net to commit, ESC to cancel.")
        }
    }
}
