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
    @Binding var routingError: String?

    @State private var transform: CanvasTransform = .default
    @State private var mouseLocation: CGPoint = .zero
    @State private var draggingWaypoint: DraggingWaypoint?

    /// Live state for the selected segment's vertex drag. Held in-view so
    /// the document isn't mutated on every gesture tick (which would kick
    /// off a 3D-preview CSG rebuild per frame). On release we apply the
    /// grid-snapped delta to the document once.
    struct DraggingWaypoint: Equatable {
        let netId: UUID
        let segmentIndex: Int
        let waypointIndex: Int
        /// Original waypoint positions of the segment at drag start. We keep
        /// them so the live preview composes deltas against a stable baseline
        /// rather than reading them back from the document each tick.
        let originals: [Point]
        var translation: CGSize
    }

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
                    manufacturing: manufacturing,
                    dragOverride: dragOverride
                )

                placementBodies
                placementHitTargets
                pinHandles
                routeHandles

                RoutingPreviewOverlay(
                    routingState: routingState,
                    mouseLocation: mouseLocation,
                    transform: transform,
                    gridMm: grid
                )

                // Window-level keyboard shortcuts; see SchematicCanvasView
                // for the rationale (focus-independent so child taps don't
                // mute them).
                keyShortcuts

                // Right-click catcher overlays the whole canvas. SwiftUI on
                // macOS doesn't surface secondary-button taps natively, so a
                // thin NSView fields rightMouseDown and forwards the location.
                RightClickCatcher { pt in handleRightClick(at: pt) }
                    .allowsHitTesting(true)
            }
            .clipped()
            .background(Color(NSColor.controlBackgroundColor))
            .onContinuousHover { phase in
                if case .active(let p) = phase { mouseLocation = p }
            }
            .onAppear { recomputeTransform(viewSize: geo.size) }
            .onChange(of: geo.size) { _, new in recomputeTransform(viewSize: new) }
            .onDrop(of: [.text], delegate: ParkingDropDelegate(
                document: $document,
                transform: { transform },
                gridMm: grid,
                routingLayer: routingLayer,
                selection: $selection
            ))
        }
    }

    @ViewBuilder private var keyShortcuts: some View {
        Button("Delete selection") { deleteSelection() }
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!selection.isDeletable)
            .opacity(0).frame(width: 0, height: 0)
        Button("Forward delete selection") { deleteSelection() }
            .keyboardShortcut(.deleteForward, modifiers: [])
            .disabled(!selection.isDeletable)
            .opacity(0).frame(width: 0, height: 0)
        Button("Cancel routing") {
            routingState = .idle
            selection = .none
        }
        .keyboardShortcut(.cancelAction)
        .opacity(0).frame(width: 0, height: 0)
        Button("Rotate") { rotateSelection() }
            .keyboardShortcut("r", modifiers: [])
            .disabled(selection.placementComponentId == nil)
            .opacity(0).frame(width: 0, height: 0)
        Button("Flip layer") { flipLayerSelection() }
            .keyboardShortcut("f", modifiers: [])
            .disabled(selection.placementComponentId == nil)
            .opacity(0).frame(width: 0, height: 0)
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

    // MARK: - Route waypoint handles

    /// Small draggable handles at each waypoint of the selected route segment.
    /// Dragging a handle slides that waypoint and pulls its neighbors along
    /// whichever axis keeps the adjacent Manhattan segment Manhattan.
    @ViewBuilder private var routeHandles: some View {
        if case let .routeSegment(netId, segIdx) = selection,
           let route = document.circuit.physical.routes.first(where: { $0.netId == netId }),
           segIdx < route.segments.count,
           visible.contains(route.segments[segIdx].layer) {
            let segment = route.segments[segIdx]
            let originals = segment.waypoints.map(\.position)
            let displayed = displayedWaypoints(originals: originals, netId: netId, segIdx: segIdx)
            ForEach(Array(displayed.enumerated()), id: \.offset) { i, world in
                WaypointHandle()
                    .position(transform.toScreen(world))
                    .gesture(handleDragGesture(netId: netId, segIdx: segIdx, idx: i, originals: originals))
            }
        }
    }

    /// Returns the waypoint positions to render for a given segment, applying
    /// the in-progress drag (if it targets this segment) so handles and
    /// `RoutesOverlay` stay in lockstep during the gesture.
    private func displayedWaypoints(originals: [Point], netId: UUID, segIdx: Int) -> [Point] {
        guard let drag = draggingWaypoint,
              drag.netId == netId, drag.segmentIndex == segIdx
        else { return originals }
        let deltaWorld = Point(
            x: drag.translation.width / transform.ptsPerMm,
            y: drag.translation.height / transform.ptsPerMm
        )
        return applyDrag(originals: drag.originals, index: drag.waypointIndex, delta: deltaWorld)
    }

    private var dragOverride: RoutesOverlay.DragOverride? {
        guard let drag = draggingWaypoint else { return nil }
        let deltaWorld = Point(
            x: drag.translation.width / transform.ptsPerMm,
            y: drag.translation.height / transform.ptsPerMm
        )
        let new = applyDrag(originals: drag.originals, index: drag.waypointIndex, delta: deltaWorld)
        return RoutesOverlay.DragOverride(netId: drag.netId, segmentIndex: drag.segmentIndex, waypoints: new)
    }

    private func handleDragGesture(netId: UUID, segIdx: Int, idx: Int, originals: [Point]) -> some Gesture {
        // `.global` mirrors the schematic drag fix: the handle is positioned
        // by a view that moves with the gesture's local coord space, so local
        // translations collapse to zero.
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { value in
                if draggingWaypoint == nil {
                    draggingWaypoint = DraggingWaypoint(
                        netId: netId,
                        segmentIndex: segIdx,
                        waypointIndex: idx,
                        originals: originals,
                        translation: value.translation
                    )
                } else {
                    draggingWaypoint?.translation = value.translation
                }
            }
            .onEnded { value in
                let raw = Point(
                    x: value.translation.width / transform.ptsPerMm,
                    y: value.translation.height / transform.ptsPerMm
                )
                let snapped = Point(
                    x: (raw.x / grid).rounded() * grid,
                    y: (raw.y / grid).rounded() * grid
                )
                let new = applyDrag(originals: originals, index: idx, delta: snapped)
                commitWaypoints(netId: netId, segIdx: segIdx, waypoints: new)
                draggingWaypoint = nil
            }
    }

    /// Moves only `originals[index]` by `delta`. Neighbors stay put — the
    /// polyline can become non-Manhattan, which the CAD pipeline handles
    /// (channels are swept along arbitrary 2D polylines). To restore right
    /// angles the user drags adjacent nodes or right-clicks to add new ones.
    private func applyDrag(originals: [Point], index: Int, delta: Point) -> [Point] {
        var wps = originals
        guard (0..<wps.count).contains(index) else { return wps }
        wps[index] = Point(x: originals[index].x + delta.x,
                           y: originals[index].y + delta.y)
        return wps
    }

    private func commitWaypoints(netId: UUID, segIdx: Int, waypoints: [Point]) {
        guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId }),
              segIdx < document.circuit.physical.routes[rIdx].segments.count
        else { return }
        document.circuit.physical.routes[rIdx].segments[segIdx].waypoints =
            waypoints.map { Waypoint(position: $0) }
    }

    /// Right-click semantics:
    ///   * On a visible waypoint handle of the **selected** segment (interior
    ///     waypoints only — endpoints are anchored to pins) → delete that
    ///     waypoint.
    ///   * Otherwise, near any visible route edge → insert a new waypoint at
    ///     the projected click location. The projection keeps the inserted
    ///     point on the existing polyline so the new vertex is initially
    ///     colinear; drag a handle to introduce the bend.
    private func handleRightClick(at pt: CGPoint) {
        if case let .routeSegment(netId, segIdx) = selection,
           let waypointIdx = selectedSegmentWaypointHit(at: pt, netId: netId, segIdx: segIdx) {
            deleteWaypoint(netId: netId, segIdx: segIdx, waypointIndex: waypointIdx)
            return
        }
        insertWaypointFromRightClick(at: pt)
    }

    /// Hit-test against the interior waypoint handles of the selected segment.
    /// Endpoints are skipped: they sit on pins and removing them would silently
    /// shorten the route — surprising. Use ⌫ to delete the whole segment.
    private func selectedSegmentWaypointHit(at pt: CGPoint, netId: UUID, segIdx: Int) -> Int? {
        guard let route = document.circuit.physical.routes.first(where: { $0.netId == netId }),
              segIdx < route.segments.count
        else { return nil }
        let segment = route.segments[segIdx]
        let n = segment.waypoints.count
        // Match the handle's hit area (~22pt square → ~11pt radius).
        let threshold: Double = 11
        var best: (idx: Int, distance: Double)?
        for (i, wp) in segment.waypoints.enumerated() {
            guard i > 0, i < n - 1 else { continue }
            let screen = transform.toScreen(wp.position)
            let d = hypot(Double(pt.x - screen.x), Double(pt.y - screen.y))
            if d <= threshold, d < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (i, d)
            }
        }
        return best?.idx
    }

    private func deleteWaypoint(netId: UUID, segIdx: Int, waypointIndex: Int) {
        guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId }),
              segIdx < document.circuit.physical.routes[rIdx].segments.count
        else { return }
        var segment = document.circuit.physical.routes[rIdx].segments[segIdx]
        guard waypointIndex < segment.waypoints.count else { return }
        segment.waypoints.remove(at: waypointIndex)
        document.circuit.physical.routes[rIdx].segments[segIdx] = segment
    }

    private func insertWaypointFromRightClick(at pt: CGPoint) {
        let threshold: Double = 12
        var best: (netId: UUID, segIdx: Int, edgeIdx: Int, projected: Point, distance: Double)?
        for route in document.circuit.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                let pts = segment.waypoints.map { transform.toScreen($0.position) }
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    let d = distanceFromPoint(pt, toSegmentFrom: pts[i], to: pts[i + 1])
                    if d <= threshold, d < (best?.distance ?? .greatestFiniteMagnitude) {
                        let projScreen = projectPoint(pt, ontoSegmentFrom: pts[i], to: pts[i + 1])
                        let projWorld = transform.snap(transform.toWorld(projScreen), grid: grid)
                        best = (route.netId, segIdx, i, projWorld, d)
                    }
                }
            }
        }
        guard let hit = best,
              let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == hit.netId }),
              hit.segIdx < document.circuit.physical.routes[rIdx].segments.count
        else { return }
        document.circuit.physical.routes[rIdx].segments[hit.segIdx].waypoints
            .insert(Waypoint(position: hit.projected), at: hit.edgeIdx + 1)
        selection = .routeSegment(netId: hit.netId, segmentIndex: hit.segIdx)
    }

    private func projectPoint(_ p: CGPoint, ontoSegmentFrom a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return CGPoint(x: a.x + CGFloat(t) * dx, y: a.y + CGFloat(t) * dy)
    }

    // MARK: - Interaction

    private func handleBackgroundTap(at pt: CGPoint) {
        switch routingState {
        case .idle:
            // Hit-test route segments before deselecting. RoutesOverlay is a
            // Canvas (cheap render, no per-segment hit testing), so we test
            // here by computing point-to-polyline distance.
            if let hit = routeSegmentHit(at: pt) {
                selection = .routeSegment(netId: hit.netId, segmentIndex: hit.segmentIndex)
            } else {
                selection = .none
            }
        case .routing(let netId, var wps, let layer):
            let world = transform.snap(transform.toWorld(pt), grid: grid)
            guard let last = wps.last else { return }
            let elbow = elbow(from: last, to: world)
            if !approximatelyEqual(elbow, last) { wps.append(elbow) }
            if !approximatelyEqual(world, wps.last ?? last) { wps.append(world) }
            routingState = .routing(netId: netId, waypoints: wps, layer: layer)
        }
    }

    /// Returns the closest visible route segment whose polyline passes within
    /// the channel-stroke width of `pt` (screen pts). Nil if nothing is close.
    private func routeSegmentHit(at pt: CGPoint) -> (netId: UUID, segmentIndex: Int)? {
        // Match RoutesOverlay's stroke width and add a small slop so a click
        // near the edge of the rendered channel still hits.
        let channelStroke = max(1.5, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        let threshold = max(6.0, channelStroke / 2 + 3.0)
        var best: (netId: UUID, segmentIndex: Int, distance: Double)?
        for route in document.circuit.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                let pts = segment.waypoints.map { transform.toScreen($0.position) }
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    let d = distanceFromPoint(pt, toSegmentFrom: pts[i], to: pts[i + 1])
                    if d <= threshold, d < (best?.distance ?? .greatestFiniteMagnitude) {
                        best = (route.netId, segIdx, d)
                    }
                }
            }
        }
        return best.map { ($0.netId, $0.segmentIndex) }
    }

    private func distanceFromPoint(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            return hypot(Double(p.x - a.x), Double(p.y - a.y))
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let projX = a.x + CGFloat(t) * dx
        let projY = a.y + CGFloat(t) * dy
        return hypot(Double(p.x - projX), Double(p.y - projY))
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
            routingError = nil

        case let .routing(netId, wps, layer):
            // Same pin clicked again with only one waypoint → cancel
            if let first = wps.first, approximatelyEqual(first, world), wps.count == 1 {
                routingState = .idle
                return
            }
            // Reject if the second pin isn't on the same net as the first.
            // The physical layer is a projection of the schematic netlist —
            // it must never silently merge two electrically distinct nets.
            let pin2Ref = PinRef(componentId: componentId, pinKey: pinKey)
            let pin2Net = document.circuit.logic.nets.first(where: { $0.pins.contains(pin2Ref) })
            guard let pin2Net, pin2Net.id == netId else {
                routingError = pin2Net == nil
                    ? "That pin is not on any net — can't connect."
                    : "Pin is on a different net — connections must stay within a single net."
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

// MARK: - Route waypoint handle

/// Small draggable dot at one waypoint of the selected route segment. Visual
/// only — the drag gesture is attached at the call site so it has access to
/// the in-view drag state.
struct WaypointHandle: View {
    @State private var hovered = false

    var body: some View {
        Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
            .frame(width: hovered ? 13 : 10, height: hovered ? 13 : 10)
            .contentShape(Rectangle().size(width: 22, height: 22))
            .onHover { hovered = $0 }
            .help("Drag to reshape route")
            .animation(.easeOut(duration: 0.08), value: hovered)
    }
}

// MARK: - Right-click catcher

/// SwiftUI on macOS doesn't expose secondary-button taps, so we drop a thin
/// NSView into the hierarchy that:
///  * returns `nil` from `hitTest` so left clicks (and other gestures) pass
///    through to sibling SwiftUI views beneath it,
///  * registers a local NSEvent monitor while attached to a window so that
///    right-clicks anywhere over the host view are observed and reported
///    in SwiftUI-style (Y-down) coordinates.
struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: (CGPoint) -> Void

    func makeNSView(context: Context) -> RightClickCatcherView {
        let v = RightClickCatcherView()
        v.onRightClick = onRightClick
        return v
    }

    func updateNSView(_ nsView: RightClickCatcherView, context: Context) {
        nsView.onRightClick = onRightClick
    }
}

final class RightClickCatcherView: NSView {
    var onRightClick: ((CGPoint) -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            return
        }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .rightMouseDown) { [weak self] event in
            guard let self,
                  let win = self.window,
                  event.window === win
            else { return event }
            let appKitPoint = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(appKitPoint) else { return event }
            // NSView is Y-up from bottom; SwiftUI's local coords go Y-down from top.
            let swiftUIPoint = CGPoint(x: appKitPoint.x, y: self.bounds.height - appKitPoint.y)
            self.onRightClick?(swiftUIPoint)
            return nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
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
