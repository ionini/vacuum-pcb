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
    @State private var draggingPlacement: DraggingPlacement?

    /// Live state for placement drags. We carry the offset in-view so the
    /// body, pin handles, and hit target can render at the cursor without
    /// committing to the document on every gesture tick (which would kick
    /// off a DRC pass and 3D rebuild every frame).
    ///
    /// `withRoutes` (Cmd held at drag start) opts into rubber-band mode:
    /// every route waypoint sitting on one of the placement's pins at drag
    /// start gets dragged in tandem. `originalPosition` is captured so the
    /// final delta is computed against the start position rather than the
    /// possibly-already-mutated current `placement.position`. `attached`
    /// stores the waypoint addresses to drag — empty in plain mode.
    struct DraggingPlacement: Equatable {
        let componentId: UUID
        var translation: CGSize
        let withRoutes: Bool
        let originalPosition: Point
        let attached: Set<RouteWaypointAddress>
    }

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
                    dragOverride: dragOverride,
                    placementOverride: placementRouteOverride
                )
                ViasOverlay(
                    document: document.circuit,
                    transform: transform,
                    visible: visible,
                    manufacturing: manufacturing
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

                // NSEvent-monitor key catcher. Replaces the hidden-Button
                // approach which would silently lose its shortcut when
                // focus drifted to a non-canvas view.
                KeyEventCatcher(handlers: [
                    KeyCodes.delete: { deleteSelection() },
                    KeyCodes.forwardDelete: { deleteSelection() },
                    KeyCodes.escape: {
                        routingState = .idle
                        selection = .none
                    },
                    KeyCodes.r: { rotateSelection() },
                    KeyCodes.f: { flipLayerSelection() },
                    KeyCodes.v: { dropViaAtCursor() },
                ])

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
                    .offset(dragOffset(for: placement.componentId))
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
                        .offset(dragOffset(for: placement.componentId))
                        .gesture(placementDragGesture(placement))
                        .onTapGesture {
                            selection = .placement(componentId: placement.componentId)
                            routingState = .idle
                        }
                }
            }
        }
    }

    /// Screen-space offset to apply to all parts of a placement (body, hit
    /// target, pin handles) while the user is dragging it. Zero when this
    /// placement isn't the active drag.
    private func dragOffset(for componentId: UUID) -> CGSize {
        guard let d = draggingPlacement, d.componentId == componentId else { return .zero }
        return d.translation
    }

    private func placementDragGesture(_ placement: Placement) -> some Gesture {
        // `.global` because the hit target moves with the cursor via the
        // .offset() above — a `.local` translation would collapse as the
        // view moves under the gesture, same pattern as the schematic
        // component drag.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if draggingPlacement == nil {
                    // Sample Cmd at drag start. Holding Cmd opts into
                    // rubber-band mode where the connected route endpoints
                    // follow the placement; plain drag leaves routes alone
                    // (the standard PCB-CAD "Move" semantics, where routes
                    // are deliberate enough that you re-route by hand).
                    let withRoutes = NSEvent.modifierFlags.contains(.command)
                    draggingPlacement = DraggingPlacement(
                        componentId: placement.componentId,
                        translation: value.translation,
                        withRoutes: withRoutes,
                        originalPosition: placement.position,
                        attached: withRoutes ? attachedWaypoints(for: placement) : []
                    )
                    selection = .placement(componentId: placement.componentId)
                    routingState = .idle
                } else {
                    draggingPlacement?.translation = value.translation
                }
            }
            .onEnded { value in
                guard let drag = draggingPlacement else { return }
                let base = transform.toScreen(drag.originalPosition)
                let endWorld = transform.toWorld(
                    CGPoint(x: base.x + value.translation.width,
                            y: base.y + value.translation.height)
                )
                let snapped = transform.snap(endWorld, grid: grid)
                let delta = Point(
                    x: snapped.x - drag.originalPosition.x,
                    y: snapped.y - drag.originalPosition.y
                )
                movePlacement(drag.componentId, to: snapped)
                if drag.withRoutes {
                    for addr in drag.attached {
                        moveRouteWaypoint(addr, by: delta)
                    }
                }
                draggingPlacement = nil
            }
    }

    /// Builds the override that RoutesOverlay reads during a Cmd-drag so the
    /// connected routes visibly follow the cursor. Nil for plain drags and
    /// when there's nothing attached.
    private var placementRouteOverride: RoutesOverlay.PlacementRouteOverride? {
        guard let drag = draggingPlacement, drag.withRoutes, !drag.attached.isEmpty
        else { return nil }
        let deltaWorld = Point(
            x: drag.translation.width / transform.ptsPerMm,
            y: drag.translation.height / transform.ptsPerMm
        )
        return RoutesOverlay.PlacementRouteOverride(delta: deltaWorld, attached: drag.attached)
    }

    /// Every waypoint sitting on one of this placement's pins, captured at
    /// drag start so the document can be queried once instead of every
    /// frame. Matching is positional (0.05 mm) which is the same tolerance
    /// the DRC graph uses, so any pin-coincident waypoint is included —
    /// including vias that happen to land on a pin.
    private func attachedWaypoints(for placement: Placement) -> Set<RouteWaypointAddress> {
        guard let component = component(for: placement.componentId) else { return [] }
        let pinWorlds = component.footprint.pins.map { placement.worldPosition(of: $0) }
        var result: Set<RouteWaypointAddress> = []
        for route in document.circuit.physical.routes {
            for (sIdx, segment) in route.segments.enumerated() {
                for (wIdx, wp) in segment.waypoints.enumerated() {
                    if pinWorlds.contains(where: {
                        abs($0.x - wp.position.x) < 0.05 && abs($0.y - wp.position.y) < 0.05
                    }) {
                        result.insert(RouteWaypointAddress(
                            netId: route.netId, segmentIndex: sIdx, waypointIndex: wIdx
                        ))
                    }
                }
            }
        }
        return result
    }

    private func moveRouteWaypoint(_ a: RouteWaypointAddress, by delta: Point) {
        guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == a.netId }),
              a.segmentIndex < document.circuit.physical.routes[rIdx].segments.count,
              a.waypointIndex < document.circuit.physical.routes[rIdx].segments[a.segmentIndex].waypoints.count
        else { return }
        let current = document.circuit.physical.routes[rIdx].segments[a.segmentIndex].waypoints[a.waypointIndex].position
        document.circuit.physical.routes[rIdx].segments[a.segmentIndex].waypoints[a.waypointIndex].position =
            Point(x: current.x + delta.x, y: current.y + delta.y)
    }

    private func hitSize(for c: Component) -> CGSize {
        // Footprint exclusion-rect dimensions in pts, padded so small parts
        // (especially ports at ~3 mm) stay easy to grab even when zoomed in
        // close to their actual size. 40 pt minimum keeps the cursor target
        // comfortable for a trackpad without overlapping neighbouring parts
        // on a typical board.
        let bounds = c.footprint.boundingRect
        let w = max(40, bounds.size.width * transform.ptsPerMm + 12)
        let h = max(40, bounds.size.height * transform.ptsPerMm + 12)
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
                            .offset(dragOffset(for: placement.componentId))
                        }
                    }
                }
            }
        }
    }

    private func isFirstRoutingPin(componentId: UUID, key: String) -> Bool {
        guard case let .routing(_, waypoints, _, _) = routingState,
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
        // Preserve each waypoint's kind by index — drag only mutates positions,
        // never the count, so the index→kind mapping survives. Skipping this
        // would silently turn every via into a plain .point and orphan the
        // sibling on the other layer.
        let previous = document.circuit.physical.routes[rIdx].segments[segIdx].waypoints
        let newWaypoints = waypoints.enumerated().map { i, p -> Waypoint in
            let kind: WaypointKind = i < previous.count ? previous[i].kind : .point
            return Waypoint(position: p, kind: kind)
        }
        document.circuit.physical.routes[rIdx].segments[segIdx].waypoints = newWaypoints

        // Drag any sibling via on another segment that shared the old XY.
        for i in 0..<min(previous.count, waypoints.count) {
            guard previous[i].kind == .via else { continue }
            let oldPos = previous[i].position
            let newPos = waypoints[i]
            if abs(oldPos.x - newPos.x) < 0.001 && abs(oldPos.y - newPos.y) < 0.001 { continue }
            moveSiblingVias(netId: netId, excluding: segIdx, from: oldPos, to: newPos)
        }
    }

    /// Vias are paired — the matching via lives on a different segment of
    /// the same net. When the dragged via moves, find every other via on the
    /// net that was sitting at the old XY and drag it to the new XY too so
    /// the cross-plate bore stays joined.
    private func moveSiblingVias(netId: UUID, excluding segIdx: Int, from oldPos: Point, to newPos: Point) {
        guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId })
        else { return }
        for sIdx in document.circuit.physical.routes[rIdx].segments.indices where sIdx != segIdx {
            let waypoints = document.circuit.physical.routes[rIdx].segments[sIdx].waypoints
            for (wIdx, wp) in waypoints.enumerated() where wp.kind == .via {
                if abs(wp.position.x - oldPos.x) < 0.05 && abs(wp.position.y - oldPos.y) < 0.05 {
                    document.circuit.physical.routes[rIdx].segments[sIdx].waypoints[wIdx].position = newPos
                }
            }
        }
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
        case .routing(let netId, var wps, let layer, let startsAtVia):
            let world = transform.snap(transform.toWorld(pt), grid: grid)
            guard let last = wps.last else { return }
            let elbow = elbow(from: last, to: world)
            if !approximatelyEqual(elbow, last) { wps.append(elbow) }
            if !approximatelyEqual(world, wps.last ?? last) { wps.append(world) }
            routingState = .routing(netId: netId, waypoints: wps, layer: layer, startsAtVia: startsAtVia)
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
            routingState = .routing(netId: net.id, waypoints: [world], layer: pinLayer, startsAtVia: false)
            selection = .none
            routingError = nil

        case let .routing(netId, wps, layer, startsAtVia):
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
            appendRouteSegment(netId: netId, points: finalPath, layer: layer, startsAtVia: startsAtVia)
            routingState = .idle
            _ = pinLayer // referenced for future layer-mismatch warning
        }
    }

    /// Place a via at the snapped cursor position while mid-route. Commits
    /// the in-progress segment with the via as its terminating waypoint, then
    /// restarts routing from the same XY on the *other* layer (same net), with
    /// startsAtVia=true so the next commit emits the matching via on the new
    /// segment's first waypoint.
    private func dropViaAtCursor() {
        guard case let .routing(netId, wps, layer, startsAtVia) = routingState else { return }
        let cursorWorld = transform.snap(transform.toWorld(mouseLocation), grid: grid)
        guard let last = wps.last else { return }

        // Build the polyline that ends at the via, joining with an auto-elbow
        // the same way a normal pin commit does. The first waypoint may itself
        // be a via if this segment was started by a previous V press.
        var finalPath: [Waypoint] = []
        for (i, p) in wps.enumerated() {
            let kind: WaypointKind = (i == 0 && startsAtVia) ? .via : .point
            finalPath.append(Waypoint(position: p, kind: kind))
        }
        let elbow = elbow(from: last, to: cursorWorld)
        if !approximatelyEqual(elbow, last) {
            finalPath.append(Waypoint(position: elbow, kind: .point))
        }
        finalPath.append(Waypoint(position: cursorWorld, kind: .via))

        let segment = Segment(waypoints: finalPath, layer: layer)
        if let i = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId }) {
            document.circuit.physical.routes[i].segments.append(segment)
        } else {
            document.circuit.physical.routes.append(Route(netId: netId, segments: [segment]))
        }

        // Continue routing from the via on the other layer.
        let nextLayer: Layer = layer == .top ? .bottom : .top
        routingLayer = nextLayer
        routingState = .routing(netId: netId, waypoints: [cursorWorld], layer: nextLayer, startsAtVia: true)
    }

    private func appendRouteSegment(netId: UUID, points: [Point], layer: Layer, startsAtVia: Bool) {
        guard points.count >= 2 else { return }
        let waypoints = points.enumerated().map { i, p in
            Waypoint(position: p, kind: (i == 0 && startsAtVia) ? .via : .point)
        }
        let segment = Segment(waypoints: waypoints, layer: layer)
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
