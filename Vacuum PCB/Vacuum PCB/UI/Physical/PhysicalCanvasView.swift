import SwiftUI
import UniformTypeIdentifiers

/// The main physical 2D editor: board outline, grid, placements, routes,
/// routing preview, pin handles, and keyboard / drop / hit interaction.
struct PhysicalCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: PhysicalSelection
    @Binding var routingState: RoutingState
    @Binding var visible: LayerVisibility
    @Binding var routingLayer: Layer

    @State private var transform: CanvasTransform = .default
    @State private var mouseLocation: CGPoint = .zero
    @FocusState private var canvasFocused: Bool

    private var manufacturing: ManufacturingConstants { document.circuit.manufacturing }
    private var grid: Double { manufacturing.gridPitch }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(NSColor.controlBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { pt in
                        handleBackgroundTap(at: pt)
                    }

                gridLines(in: geo.size)
                boardOutline

                RoutesOverlay(
                    document: document.circuit,
                    transform: transform,
                    visible: visible,
                    selection: selection,
                    manufacturing: manufacturing
                )

                placementBodies
                placementHitTargets
                pinHandles

                RoutingPreviewOverlay(
                    routingState: routingState,
                    mouseLocation: mouseLocation,
                    transform: transform,
                    gridMm: grid
                )
            }
            .clipped()
            .background(Color(NSColor.controlBackgroundColor))
            .onContinuousHover { phase in
                if case .active(let p) = phase { mouseLocation = p }
            }
            .focusable()
            .focused($canvasFocused)
            .onAppear {
                recomputeTransform(viewSize: geo.size)
                canvasFocused = true
            }
            .onChange(of: geo.size) { _, new in recomputeTransform(viewSize: new) }
            .onKeyPress(.escape) { routingState = .idle; selection = .none; return .handled }
            .onKeyPress(.delete)        { deleteSelection(); return .handled }
            .onKeyPress(.deleteForward) { deleteSelection(); return .handled }
            .onKeyPress("r")            { rotateSelection(); return .handled }
            .onKeyPress("R")            { rotateSelection(); return .handled }
            .onKeyPress("f")            { flipLayerSelection(); return .handled }
            .onKeyPress("F")            { flipLayerSelection(); return .handled }
            .onDrop(of: [.text], delegate: ParkingDropDelegate(
                document: $document,
                transform: { transform },
                gridMm: grid,
                routingLayer: routingLayer,
                selection: $selection
            ))
        }
    }

    // MARK: - Background visuals

    private func gridLines(in size: CGSize) -> some View {
        Canvas { ctx, _ in
            let outline = document.circuit.physical.boardOutline
            let gridColor = Color.primary.opacity(0.10)
            var path = Path()
            let step = grid
            var x = outline.origin.x
            while x <= outline.maxX + 0.001 {
                let a = transform.toScreen(Point(x: x, y: outline.origin.y))
                let b = transform.toScreen(Point(x: x, y: outline.maxY))
                path.move(to: a); path.addLine(to: b)
                x += step
            }
            var y = outline.origin.y
            while y <= outline.maxY + 0.001 {
                let a = transform.toScreen(Point(x: outline.origin.x, y: y))
                let b = transform.toScreen(Point(x: outline.maxX,    y: y))
                path.move(to: a); path.addLine(to: b)
                y += step
            }
            ctx.stroke(path, with: .color(gridColor), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var boardOutline: some View {
        Canvas { ctx, _ in
            let outline = document.circuit.physical.boardOutline
            let a = transform.toScreen(Point(x: outline.minX, y: outline.minY))
            let b = transform.toScreen(Point(x: outline.maxX, y: outline.maxY))
            let rect = CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
            ctx.stroke(Path(roundedRect: rect, cornerRadius: 2),
                       with: .color(Color.primary.opacity(0.7)), lineWidth: 1.5)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Placement layers

    private var placementBodies: some View {
        ZStack {
            ForEach(document.circuit.physical.placements, id: \.componentId) { placement in
                if visible.contains(placement.layer),
                   let component = component(for: placement.componentId) {
                    PlacementBodyView(
                        component: component,
                        placement: placement,
                        manufacturing: manufacturing,
                        transform: transform,
                        visible: visible,
                        isSelected: selection.placementComponentId == placement.componentId
                    )
                }
            }
        }
    }

    /// Invisible draggable hit targets — separate from the visual body so the
    /// body can be a non-interactive Canvas (cheaper) and we can carry per-
    /// component drag state without conflicting with click handlers.
    private var placementHitTargets: some View {
        ZStack {
            ForEach(document.circuit.physical.placements, id: \.componentId) { placement in
                if visible.contains(placement.layer),
                   let component = component(for: placement.componentId) {
                    let pos = transform.toScreen(placement.position)
                    let size = hitSize(for: component)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: size.width, height: size.height)
                        .position(pos)
                        .gesture(
                            DragGesture(minimumDistance: 2)
                                .onChanged { _ in
                                    selection = .placement(componentId: placement.componentId)
                                }
                                .onEnded { value in
                                    let endWorld = transform.toWorld(
                                        CGPoint(x: pos.x + value.translation.width,
                                                y: pos.y + value.translation.height)
                                    )
                                    let snapped = transform.snap(endWorld, grid: grid)
                                    movePlacement(placement.componentId, to: snapped)
                                }
                        )
                        .onTapGesture {
                            selection = .placement(componentId: placement.componentId)
                            routingState = .idle
                        }
                }
            }
        }
    }

    private func hitSize(for c: Component) -> CGSize {
        // Footprint exclusion-rect dimensions in pts.
        let bounds = c.footprint.boundingRect
        let w = max(20, bounds.size.width * transform.ptsPerMm)
        let h = max(20, bounds.size.height * transform.ptsPerMm)
        return CGSize(width: w, height: h)
    }

    // MARK: - Pin handles

    private var pinHandles: some View {
        ZStack {
            ForEach(document.circuit.physical.placements, id: \.componentId) { placement in
                if let component = component(for: placement.componentId) {
                    ForEach(component.footprint.pins, id: \.key) { pin in
                        let layer = placement.resolvedLayer(of: pin)
                        if visible.contains(layer) {
                            let world = placement.worldPosition(of: pin)
                            let screen = transform.toScreen(world)
                            PhysicalPinHandle(
                                pinKey: pin.key,
                                layer: layer,
                                isFirstOfRouting: isFirstRoutingPin(componentId: placement.componentId, key: pin.key)
                            ) {
                                handlePinTap(componentId: placement.componentId, pinKey: pin.key)
                            }
                            .position(screen)
                        }
                    }
                }
            }
        }
    }

    private func isFirstRoutingPin(componentId: UUID, key: String) -> Bool {
        guard case let .routing(_, waypoints, _) = routingState,
              let firstWP = waypoints.first,
              let placement = document.circuit.physical.placements.first(where: { $0.componentId == componentId }),
              let component = component(for: componentId),
              let pin = component.footprint.pin(key)
        else { return false }
        let world = placement.worldPosition(of: pin)
        return abs(world.x - firstWP.x) < 0.001 && abs(world.y - firstWP.y) < 0.001
    }

    // MARK: - Interaction

    private func handleBackgroundTap(at pt: CGPoint) {
        switch routingState {
        case .idle:
            selection = .none
        case .routing(let netId, var wps, let layer):
            let world = transform.snap(transform.toWorld(pt), grid: grid)
            guard let last = wps.last else { return }
            let elbow = elbow(from: last, to: world)
            if !approximatelyEqual(elbow, last) { wps.append(elbow) }
            if !approximatelyEqual(world, wps.last ?? last) { wps.append(world) }
            routingState = .routing(netId: netId, waypoints: wps, layer: layer)
        }
    }

    private func handlePinTap(componentId: UUID, pinKey: String) {
        guard let placement = document.circuit.physical.placements.first(where: { $0.componentId == componentId }),
              let component = component(for: componentId),
              let pin = component.footprint.pin(pinKey)
        else { return }
        let world = placement.worldPosition(of: pin)
        let pinLayer = placement.resolvedLayer(of: pin)

        switch routingState {
        case .idle:
            // Need a net for this pin. Look it up.
            let ref = PinRef(componentId: componentId, pinKey: pinKey)
            guard let net = document.circuit.logic.nets.first(where: { $0.pins.contains(ref) }) else {
                // Pin not on any net — no route to start. Select the placement instead.
                selection = .placement(componentId: componentId)
                return
            }
            // Auto-pick the route layer from the pin so the channel actually connects.
            // The bottom-strip layer picker still works for changing direction mid-route.
            routingLayer = pinLayer
            routingState = .routing(netId: net.id, waypoints: [world], layer: pinLayer)
            selection = .none

        case let .routing(netId, wps, layer):
            // Same pin clicked again with only one waypoint → cancel
            if let first = wps.first, approximatelyEqual(first, world), wps.count == 1 {
                routingState = .idle
                return
            }
            // Commit a segment to the route.
            // Append Manhattan path from last waypoint to this pin.
            var finalPath = wps
            if let last = finalPath.last {
                let elbow = elbow(from: last, to: world)
                if !approximatelyEqual(elbow, last) { finalPath.append(elbow) }
                if !approximatelyEqual(world, finalPath.last ?? last) { finalPath.append(world) }
            }
            appendRouteSegment(netId: netId, points: finalPath, layer: layer)
            routingState = .idle
            _ = pinLayer // referenced for future layer-mismatch warning
        }
    }

    private func appendRouteSegment(netId: UUID, points: [Point], layer: Layer) {
        guard points.count >= 2 else { return }
        let segment = Segment(
            waypoints: points.map { Waypoint(position: $0) },
            layer: layer
        )
        if let i = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId }) {
            document.circuit.physical.routes[i].segments.append(segment)
        } else {
            document.circuit.physical.routes.append(Route(netId: netId, segments: [segment]))
        }
    }

    private func movePlacement(_ componentId: UUID, to position: Point) {
        guard let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == componentId })
        else { return }
        document.circuit.physical.placements[i].position = position
    }

    private func deleteSelection() {
        switch selection {
        case .placement(let id):
            document.circuit.physical.placements.removeAll { $0.componentId == id }
        case .routeSegment(let netId, let segIdx):
            guard let i = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId })
            else { break }
            if segIdx < document.circuit.physical.routes[i].segments.count {
                document.circuit.physical.routes[i].segments.remove(at: segIdx)
            }
            if document.circuit.physical.routes[i].segments.isEmpty {
                document.circuit.physical.routes.remove(at: i)
            }
        case .none:
            break
        }
        selection = .none
    }

    private func rotateSelection() {
        guard case let .placement(id) = selection,
              let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id })
        else { return }
        let next: Rotation
        switch document.circuit.physical.placements[i].rotation {
        case .r0: next = .r90
        case .r90: next = .r180
        case .r180: next = .r270
        case .r270: next = .r0
        }
        document.circuit.physical.placements[i].rotation = next
    }

    private func flipLayerSelection() {
        guard case let .placement(id) = selection,
              let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id })
        else { return }
        let cur = document.circuit.physical.placements[i].layer
        document.circuit.physical.placements[i].layer = cur == .top ? .bottom : .top
    }

    // MARK: - Helpers

    private func recomputeTransform(viewSize: CGSize) {
        guard viewSize.width > 50, viewSize.height > 50 else { return }
        transform = CanvasTransform.fit(
            rect: document.circuit.physical.boardOutline,
            in: viewSize,
            margin: 36
        )
    }

    private func component(for id: UUID) -> Component? {
        document.circuit.logic.components.first(where: { $0.id == id })
    }

    private func elbow(from a: Point, to b: Point) -> Point {
        let dx = abs(b.x - a.x)
        let dy = abs(b.y - a.y)
        return dx >= dy ? Point(x: b.x, y: a.y) : Point(x: a.x, y: b.y)
    }

    private func approximatelyEqual(_ a: Point, _ b: Point, eps: Double = 0.05) -> Bool {
        abs(a.x - b.x) < eps && abs(a.y - b.y) < eps
    }
}

// MARK: - Physical pin handle

struct PhysicalPinHandle: View {
    let pinKey: String
    let layer: Layer
    let isFirstOfRouting: Bool
    let onTap: () -> Void

    @State private var hovered = false

    var body: some View {
        Circle()
            .fill(fillColor)
            .overlay(Circle().stroke(strokeColor, lineWidth: 1.0))
            .frame(width: 9, height: 9)
            .contentShape(Rectangle().size(width: 20, height: 20))
            .onHover { hovered = $0 }
            .onTapGesture { onTap() }
            .help(pinKey)
    }

    private var fillColor: Color {
        if isFirstOfRouting { return .accentColor }
        if hovered { return .accentColor.opacity(0.5) }
        return layer == .top ? Color.blue.opacity(0.7) : Color.teal.opacity(0.7)
    }

    private var strokeColor: Color {
        if isFirstOfRouting { return .accentColor }
        return .primary.opacity(0.85)
    }
}

// MARK: - Drop delegate for parking-lot drops

struct ParkingDropDelegate: DropDelegate {
    @Binding var document: VPCBDocument
    let transform: () -> CanvasTransform
    let gridMm: Double
    let routingLayer: Layer
    @Binding var selection: PhysicalSelection

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let dropPoint = info.location
        let tx = transform()
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            DispatchQueue.main.async {
                guard let idString = stringFromItem(item),
                      let id = UUID(uuidString: idString),
                      document.circuit.logic.components.contains(where: { $0.id == id })
                else { return }
                let world = tx.snap(tx.toWorld(dropPoint), grid: gridMm)
                createOrMovePlacement(id: id, to: world)
                selection = .placement(componentId: id)
            }
        }
        return true
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    private func createOrMovePlacement(id: UUID, to world: Point) {
        if let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id }) {
            document.circuit.physical.placements[i].position = world
        } else {
            // Default layer: bottom for transistor (dimple convention), top for others.
            let component = document.circuit.logic.components.first(where: { $0.id == id })
            let defaultLayer: Layer = (component?.kind == .transistor) ? .bottom : .top
            document.circuit.physical.placements.append(
                Placement(componentId: id, position: world, rotation: .r0, layer: defaultLayer)
            )
        }
    }

    private func stringFromItem(_ item: NSSecureCoding?) -> String? {
        if let s = item as? String { return s }
        if let d = item as? Data { return String(data: d, encoding: .utf8) }
        if let url = item as? URL { return url.absoluteString }
        return nil
    }
}
