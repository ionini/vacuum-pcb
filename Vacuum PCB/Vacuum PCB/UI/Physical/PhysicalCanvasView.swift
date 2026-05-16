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
    var showRatsnest: Bool

    @State private var transform: CanvasTransform = .default
    @State private var mouseLocation: CGPoint = .zero
    @State private var draggingWaypoint: DraggingWaypoint?
    @State private var draggingPlacement: DraggingPlacement?

    /// Live state for placement drags. We carry the offset in-view so the
    /// body, pin handles, and hit target can render at the cursor without
    /// committing to the document on every gesture tick (which would kick
    /// off a DRC pass and 3D rebuild every frame).
    ///
    /// `originals` is keyed by componentId — multi-placement drag (when the
    /// user grabs a member of an existing multi-selection) puts every
    /// selected placement in the dictionary and moves them by the same
    /// world-space delta. Single drag has one entry.
    ///
    /// `withRoutes` (Cmd held at drag start) opts into rubber-band mode:
    /// every route waypoint sitting on any of the dragged placements' pins
    /// at drag start gets dragged in tandem.
    struct DraggingPlacement: Equatable {
        var translation: CGSize
        let withRoutes: Bool
        let originals: [UUID: Point]
        let attached: Set<RouteWaypointAddress>
    }

    /// Live state for the marquee box-select gesture: start/current screen
    /// points captured during a background drag. Rendered as a dashed
    /// rectangle; on release, every placement whose anchor is inside the
    /// world rect joins the selection.
    @State private var marquee: MarqueeRect?

    struct MarqueeRect: Equatable {
        var startScreen: CGPoint
        var currentScreen: CGPoint

        var rect: CGRect {
            CGRect(
                x: min(startScreen.x, currentScreen.x),
                y: min(startScreen.y, currentScreen.y),
                width: abs(currentScreen.x - startScreen.x),
                height: abs(currentScreen.y - startScreen.y)
            )
        }
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

    /// Keyboard handlers for the routing toolset. V = cross-silicone via
    /// (T0 ↔ B0 only). Digit 0…9 = same-plate vertical via to that depth on
    /// the current routing plate. Both share the underlying via-drop logic.
    private var viaKeyHandlers: [UInt16: () -> Void] {
        var h: [UInt16: () -> Void] = [
            KeyCodes.delete: { deleteSelection() },
            KeyCodes.forwardDelete: { deleteSelection() },
            KeyCodes.escape: {
                routingState = .idle
                selection = .none
            },
            KeyCodes.r: { rotateSelection() },
            KeyCodes.f: { flipLayerSelection() },
            KeyCodes.v: { dropCrossSiliconeVia() },
        ]
        for (digit, code) in KeyCodes.digit.enumerated() {
            h[code] = { dropSamePlateVia(toDepth: digit) }
        }
        return h
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color(NSColor.controlBackgroundColor)
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { pt in
                        handleBackgroundTap(at: pt)
                    }
                    // Drag on empty canvas → marquee select. Min-distance 4
                    // gives SwiftUI room to disambiguate from a click.
                    .gesture(marqueeGesture)

                gridLines(in: geo.size)
                boardOutline
                subpartExpansions

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
                if showRatsnest {
                    RatsnestOverlay(document: document.circuit, transform: transform)
                }

                placementBodies
                placementHitTargets
                pinHandles
                routeHandles
                selectedWaypointMarkers

                marqueeOverlay

                RoutingPreviewOverlay(
                    routingState: routingState,
                    mouseLocation: mouseLocation,
                    transform: transform,
                    gridMm: grid
                )

                // NSEvent-monitor key catcher. Replaces the hidden-Button
                // approach which would silently lose its shortcut when
                // focus drifted to a non-canvas view.
                KeyEventCatcher(handlers: viaKeyHandlers)

                // Right-click catcher overlays the whole canvas. SwiftUI on
                // macOS doesn't surface secondary-button taps natively, so a
                // thin NSView fields rightMouseDown and forwards the location.
                RightClickCatcher { pt in handleRightClick(at: pt) }
                    .allowsHitTesting(true)
            }
            .coordinateSpace(name: "canvas")
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

    /// Sub-part instances render below the routes/placement layers so the
    /// dotted outline reads as a backdrop to the parent's own glyphs that
    /// overlap it. Each instance manages its own visibility filtering of
    /// internals by layer.
    private var subpartExpansions: some View {
        ZStack {
            ForEach(document.circuit.physical.placements, id: \.componentId) { placement in
                if let component = component(for: placement.componentId),
                   component.kind == .subpart {
                    SubpartExpandedView(
                        component: component,
                        placement: placement,
                        parentManufacturing: manufacturing,
                        transform: transform,
                        visible: visible,
                        isSelected: selection.contains(placement: placement.componentId)
                    )
                    .offset(dragOffset(for: placement.componentId))
                }
            }
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
                if visible.contains(Layer(plate: placement.layer, depth: placement.depth)),
                   let component = component(for: placement.componentId) {
                    PlacementBodyView(
                        component: component,
                        placement: placement,
                        manufacturing: manufacturing,
                        transform: transform,
                        visible: visible,
                        isSelected: selection.contains(placement: placement.componentId)
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
                if visible.contains(Layer(plate: placement.layer, depth: placement.depth)),
                   let component = component(for: placement.componentId) {
                    let pos = hitCenter(for: placement, component: component)
                    let size = hitSize(for: component)
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .frame(width: size.width, height: size.height)
                        .position(pos)
                        .offset(dragOffset(for: placement.componentId))
                        // Disable the whole hit target while the user is
                        // routing — otherwise a waypoint tap that strays
                        // into a placement's 40–60 pt halo cancels the
                        // route. Pin handles stay active so clicking a pin
                        // can still commit the route.
                        .allowsHitTesting(!routingState.inProgress)
                        .gesture(placementDragGesture(placement))
                        .onTapGesture(coordinateSpace: .named("canvas")) { pt in
                            handlePlacementTap(componentId: placement.componentId, at: pt)
                        }
                }
            }
        }
    }

    /// World→screen centre of the placement's bounding rect. Differs from
    /// `placement.position` when the footprint isn't centred on its anchor
    /// (sub-parts are corner-anchored, primitives are centre-anchored), so
    /// using the bounding-rect midpoint keeps the hit zone over the visible
    /// body for both conventions.
    private func hitCenter(for placement: Placement, component: Component) -> CGPoint {
        let b = component.footprint(manufacturing).boundingRect
        let lx = b.minX + b.size.width / 2
        let ly = b.minY + b.size.height / 2
        let r = placement.rotation.radians
        let cosR = cos(r), sinR = sin(r)
        let world = Point(
            x: placement.position.x + lx * cosR - ly * sinR,
            y: placement.position.y + lx * sinR + ly * cosR
        )
        return transform.toScreen(world)
    }

    /// Screen-space offset to apply to all parts of a placement (body, hit
    /// target, pin handles) while the user is dragging it. Zero when this
    /// placement isn't part of the active drag set.
    private func dragOffset(for componentId: UUID) -> CGSize {
        guard let d = draggingPlacement, d.originals[componentId] != nil else { return .zero }
        return d.translation
    }

    private func handlePlacementTap(componentId: UUID, at pt: CGPoint) {
        // A click that's also over a visible route segment goes to the route.
        // Sub-part hit zones can be 40+ mm wide and routinely sit on top of
        // routes traversing the body; without this, those routes are
        // unreachable. Cmd-click is preserved for multi-select on placements
        // — only plain clicks defer to the route.
        if !NSEvent.modifierFlags.contains(.command),
           let hit = routeSegmentHit(at: pt) {
            selection = .routeSegment(netId: hit.netId, segmentIndex: hit.segmentIndex)
            routingState = .idle
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            // Cmd-click toggles in/out of the multi-selection without
            // disturbing whatever else is selected. Route segment goes away
            // when we transition into multi-select on placements.
            var next = selection
            next.routeSegment = nil
            if next.placements.contains(componentId) {
                next.placements.remove(componentId)
            } else {
                next.placements.insert(componentId)
            }
            selection = next
        } else {
            selection = .placement(componentId)
        }
        routingState = .idle
    }

    private func placementDragGesture(_ placement: Placement) -> some Gesture {
        // `.global` because the hit target moves with the cursor via the
        // .offset() above — a `.local` translation would collapse as the
        // view moves under the gesture, same pattern as the schematic
        // component drag.
        DragGesture(minimumDistance: 2, coordinateSpace: .global)
            .onChanged { value in
                if draggingPlacement == nil {
                    startPlacementDrag(grabbed: placement, translation: value.translation)
                } else {
                    draggingPlacement?.translation = value.translation
                }
            }
            .onEnded { value in
                guard let drag = draggingPlacement else { return }
                // Translate the grab into a grid-aligned world delta and
                // apply it to every dragged placement + every attached
                // waypoint. Snapping the delta (not each end position)
                // keeps relative positions intact for multi-placement
                // drags — every selected placement shifts by the same
                // exact amount.
                let raw = Point(
                    x: value.translation.width / transform.ptsPerMm,
                    y: value.translation.height / transform.ptsPerMm
                )
                let delta = Point(
                    x: (raw.x / grid).rounded() * grid,
                    y: (raw.y / grid).rounded() * grid
                )
                for (id, original) in drag.originals {
                    movePlacement(id, to: Point(x: original.x + delta.x, y: original.y + delta.y))
                }
                if drag.withRoutes {
                    applyWaypointDelta(addresses: drag.attached, delta: delta)
                }
                draggingPlacement = nil
            }
    }

    /// Builds the drag set the moment the user starts pulling on a placement.
    /// - If the grabbed placement is part of an existing multi-selection,
    ///   drag every selected placement (and any marquee-selected waypoints)
    ///   together. The selection itself is unchanged.
    /// - Otherwise the grabbed placement becomes the new sole selection and
    ///   it's the only thing that drags.
    /// Cmd held at this moment opts into rubber-band mode, capturing every
    /// route waypoint sitting on any pin of any dragged placement on top of
    /// whatever the selection already carries.
    private func startPlacementDrag(grabbed placement: Placement, translation: CGSize) {
        let withRoutes = NSEvent.modifierFlags.contains(.command)
        let dragSet: Set<UUID>
        var carriedWaypoints: Set<RouteWaypointAddress> = []
        if selection.contains(placement: placement.componentId), selection.placements.count > 1 {
            dragSet = selection.placements
            carriedWaypoints = selection.waypoints
        } else {
            dragSet = [placement.componentId]
            // Replace selection — but preserve the just-grabbed placement's
            // selection. (Marquee-selected waypoints get dropped when the
            // user clicks a single placement; matches their mental model.)
            selection = .placement(placement.componentId)
        }
        var originals: [UUID: Point] = [:]
        for id in dragSet {
            if let p = document.circuit.physical.placements.first(where: { $0.componentId == id }) {
                originals[id] = p.position
            }
        }
        var attached = carriedWaypoints
        if withRoutes {
            attached.formUnion(attachedWaypoints(forComponentIds: dragSet))
        }
        draggingPlacement = DraggingPlacement(
            translation: translation,
            withRoutes: withRoutes || !carriedWaypoints.isEmpty,
            originals: originals,
            attached: attached
        )
        routingState = .idle
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

    /// Every waypoint sitting on a pin of any placement in `componentIds`.
    /// Matching is positional (0.05 mm) which is the same tolerance the DRC
    /// graph uses, so any pin-coincident waypoint is included — including
    /// vias that happen to land on a pin.
    private func attachedWaypoints(forComponentIds componentIds: Set<UUID>) -> Set<RouteWaypointAddress> {
        // Resolve every pin world position across the dragged placements.
        var pinWorlds: [Point] = []
        for id in componentIds {
            guard let placement = document.circuit.physical.placements.first(where: { $0.componentId == id }),
                  let component = component(for: id)
            else { continue }
            for pin in component.footprint(manufacturing).pins {
                pinWorlds.append(placement.worldPosition(of: pin))
            }
        }
        guard !pinWorlds.isEmpty else { return [] }
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

    /// Shift a batch of waypoints by the same world-space delta in one pass.
    /// Snapshots each original position first, then writes `original + delta`
    /// directly — that way the sibling-via callback fired while writing one
    /// via doesn't corrupt the next iteration's read of another via in the
    /// same batch (which would result in a 2× delta for paired vias caught
    /// by the same marquee).
    ///
    /// Sibling-via propagation still happens for vias whose twin isn't in
    /// the batch (e.g. a pin-coincident via caught by Cmd-drag rubber-band
    /// rather than the marquee). Twins already in the batch are skipped so
    /// they aren't moved twice.
    private func applyWaypointDelta(addresses: Set<RouteWaypointAddress>, delta: Point) {
        struct Snapshot {
            let oldPosition: Point
            let kind: WaypointKind
        }
        var snapshot: [RouteWaypointAddress: Snapshot] = [:]
        for addr in addresses {
            guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == addr.netId }),
                  addr.segmentIndex < document.circuit.physical.routes[rIdx].segments.count,
                  addr.waypointIndex < document.circuit.physical.routes[rIdx].segments[addr.segmentIndex].waypoints.count
            else { continue }
            let wp = document.circuit.physical.routes[rIdx].segments[addr.segmentIndex].waypoints[addr.waypointIndex]
            snapshot[addr] = Snapshot(oldPosition: wp.position, kind: wp.kind)
        }

        let inBatch = Set(snapshot.keys)
        for (addr, snap) in snapshot {
            guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == addr.netId })
            else { continue }
            let newPos = Point(x: snap.oldPosition.x + delta.x, y: snap.oldPosition.y + delta.y)
            document.circuit.physical.routes[rIdx].segments[addr.segmentIndex].waypoints[addr.waypointIndex].position = newPos
            if snap.kind == .via {
                moveSiblingVias(
                    netId: addr.netId, excluding: addr.segmentIndex,
                    from: snap.oldPosition, to: newPos, skipping: inBatch
                )
            }
        }
    }

    private func hitSize(for c: Component) -> CGSize {
        // Footprint exclusion-rect dimensions in pts, padded so small parts
        // stay easy to grab. The arrowhead glyph for ports / rails extends
        // well past the pin anchor — and the tip is exactly what users aim
        // at — so give those kinds a generous minimum target.
        let bounds = c.footprint(manufacturing).boundingRect
        let isArrowLike: Bool = (c.kind == .port || c.kind == .vacuumSource || c.kind == .atmVent)
        let minSize: Double = isArrowLike ? 60 : 40
        let w = max(minSize, bounds.size.width * transform.ptsPerMm + 12)
        let h = max(minSize, bounds.size.height * transform.ptsPerMm + 12)
        return CGSize(width: w, height: h)
    }

    // MARK: - Pin handles

    private var pinHandles: some View {
        ZStack {
            ForEach(document.circuit.physical.placements, id: \.componentId) { placement in
                if let component = component(for: placement.componentId) {
                    ForEach(component.footprint(manufacturing).pins, id: \.key) { pin in
                        // Subpart boundary pins live on the library file's
                        // plate (depth 0) regardless of the instance's
                        // placement.layer — that field is metadata-only for
                        // subparts. Primitives resolve through the standard
                        // relative-layer rule.
                        let pinLayer: Layer = {
                            if let bp = component.subpartBoundaryPin(key: pin.key) {
                                return Layer(plate: bp.plate, depth: 0)
                            }
                            return placement.resolvedLayer(of: pin, on: component)
                        }()
                        if visible.contains(pinLayer) {
                            let world = placement.worldPosition(of: pin)
                            let screen = transform.toScreen(world)
                            PhysicalPinHandle(
                                pinKey: pinDisplayLabel(component: component, key: pin.key),
                                layer: pinLayer,
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

    /// Sub-part pin keys are port UUID strings; map them back to the
    /// boundary component's friendly label for tooltip display. Primitive
    /// pin keys ("gate", "a", "1", "p") pass through unchanged.
    private func pinDisplayLabel(component: Component, key: String) -> String {
        guard component.kind == .subpart,
              let filename = component.partRef,
              let part = PartsLibrary.shared.part(named: filename),
              let pin = part.pins.first(where: { $0.portId.uuidString == key })
        else { return key }
        return pin.label
    }

    private func isFirstRoutingPin(componentId: UUID, key: String) -> Bool {
        guard case let .routing(_, waypoints, _, _) = routingState,
              let firstWP = waypoints.first,
              let placement = document.circuit.physical.placements.first(where: { $0.componentId == componentId }),
              let component = component(for: componentId),
              let pin = component.footprint(manufacturing).pin(key)
        else { return false }
        let world = placement.worldPosition(of: pin)
        return abs(world.x - firstWP.x) < 0.001 && abs(world.y - firstWP.y) < 0.001
    }

    // MARK: - Route waypoint handles

    /// Small draggable handles at each waypoint of the selected route segment.
    /// Dragging a handle slides that waypoint and pulls its neighbors along
    /// whichever axis keeps the adjacent Manhattan segment Manhattan.
    @ViewBuilder private var routeHandles: some View {
        if let seg = selection.routeSegment,
           let route = document.circuit.physical.routes.first(where: { $0.netId == seg.netId }),
           seg.segmentIndex < route.segments.count,
           visible.contains(route.segments[seg.segmentIndex].layer) {
            let segment = route.segments[seg.segmentIndex]
            let originals = segment.waypoints.map(\.position)
            let displayed = displayedWaypoints(originals: originals, netId: seg.netId, segIdx: seg.segmentIndex)
            ForEach(Array(displayed.enumerated()), id: \.offset) { i, world in
                WaypointHandle()
                    .position(transform.toScreen(world))
                    .gesture(handleDragGesture(netId: seg.netId, segIdx: seg.segmentIndex, idx: i, originals: originals))
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
    ///
    /// `skipping` lets a batch caller (e.g. marquee multi-via drag) flag
    /// waypoints it's already moving directly, so a sibling that's also in
    /// the batch doesn't get shifted twice.
    private func moveSiblingVias(
        netId: UUID, excluding segIdx: Int,
        from oldPos: Point, to newPos: Point,
        skipping: Set<RouteWaypointAddress> = []
    ) {
        guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId })
        else { return }
        for sIdx in document.circuit.physical.routes[rIdx].segments.indices where sIdx != segIdx {
            let waypoints = document.circuit.physical.routes[rIdx].segments[sIdx].waypoints
            for (wIdx, wp) in waypoints.enumerated() where wp.kind == .via {
                guard abs(wp.position.x - oldPos.x) < 0.05,
                      abs(wp.position.y - oldPos.y) < 0.05
                else { continue }
                let key = RouteWaypointAddress(
                    netId: netId, segmentIndex: sIdx, waypointIndex: wIdx
                )
                if skipping.contains(key) { continue }
                document.circuit.physical.routes[rIdx].segments[sIdx].waypoints[wIdx].position = newPos
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
        if let seg = selection.routeSegment,
           let waypointIdx = selectedSegmentWaypointHit(at: pt, netId: seg.netId, segIdx: seg.segmentIndex) {
            deleteWaypoint(netId: seg.netId, segIdx: seg.segmentIndex, waypointIndex: waypointIdx)
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

    /// Bulk-delete everything in the current selection:
    ///  * placements (just remove the placement; the logic-side component
    ///    isn't touched — schematic edits delete those),
    ///  * the focused route segment,
    ///  * every segment that contains a marquee-selected waypoint (so a
    ///    Cmd-marquee around a subcircuit can wipe the routes too).
    ///
    /// We collect the segment-removal set first, then process per-net in
    /// descending segment-index order so removing earlier segments doesn't
    /// shift indices of segments we still want to remove.
    private func deleteCurrentSelection() {
        if !selection.placements.isEmpty {
            for id in selection.placements {
                document.circuit.physical.placements.removeAll { $0.componentId == id }
            }
        }

        // Build the (netId, segmentIndex) set to remove from waypoint hits
        // and the focused route segment.
        var toRemove: [UUID: Set<Int>] = [:]
        for addr in selection.waypoints {
            toRemove[addr.netId, default: []].insert(addr.segmentIndex)
        }
        if let seg = selection.routeSegment {
            toRemove[seg.netId, default: []].insert(seg.segmentIndex)
        }

        for (netId, segIndices) in toRemove {
            guard let rIdx = document.circuit.physical.routes.firstIndex(where: { $0.netId == netId })
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

    private func projectPoint(_ p: CGPoint, ontoSegmentFrom a: CGPoint, to b: CGPoint) -> CGPoint {
        let dx = b.x - a.x
        let dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return a }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return CGPoint(x: a.x + CGFloat(t) * dx, y: a.y + CGFloat(t) * dy)
    }

    // MARK: - Marquee-selected waypoint markers

    /// Small accent dots at every `selection.waypoints` entry, useful when
    /// the user has marquee-selected interior route bends. Follows the live
    /// drag delta so the dots track with the polyline during a Cmd-drag.
    @ViewBuilder private var selectedWaypointMarkers: some View {
        let drag = draggingPlacement
        Canvas { ctx, _ in
            for addr in selection.waypoints {
                guard let route = document.circuit.physical.routes.first(where: { $0.netId == addr.netId }),
                      addr.segmentIndex < route.segments.count
                else { continue }
                let segment = route.segments[addr.segmentIndex]
                guard visible.contains(segment.layer),
                      addr.waypointIndex < segment.waypoints.count
                else { continue }
                var pos = segment.waypoints[addr.waypointIndex].position
                if let d = drag, d.attached.contains(addr) {
                    pos = Point(
                        x: pos.x + d.translation.width / transform.ptsPerMm,
                        y: pos.y + d.translation.height / transform.ptsPerMm
                    )
                }
                let screen = transform.toScreen(pos)
                let r: CGFloat = 5
                let rect = CGRect(x: screen.x - r, y: screen.y - r, width: r * 2, height: r * 2)
                ctx.fill(Path(ellipseIn: rect), with: .color(Color.accentColor.opacity(0.85)))
                ctx.stroke(Path(ellipseIn: rect),
                           with: .color(.white), lineWidth: 1.2)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Marquee

    @ViewBuilder private var marqueeOverlay: some View {
        if let m = marquee {
            Rectangle()
                .fill(Color.accentColor.opacity(0.12))
                .overlay(
                    Rectangle()
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.0, dash: [4, 3]))
                )
                .frame(width: m.rect.width, height: m.rect.height)
                .position(x: m.rect.midX, y: m.rect.midY)
                .allowsHitTesting(false)
        }
    }

    private var marqueeGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                marquee = MarqueeRect(
                    startScreen: value.startLocation,
                    currentScreen: value.location
                )
            }
            .onEnded { value in
                defer { marquee = nil }
                let rect = MarqueeRect(
                    startScreen: value.startLocation,
                    currentScreen: value.location
                ).rect
                // Tiny rectangles (sub-grid) are likely fumbled clicks — treat
                // as a no-op rather than wiping the selection silently.
                guard rect.width > 2 || rect.height > 2 else { return }
                applyMarquee(screenRect: rect, additive: NSEvent.modifierFlags.contains(.command))
            }
    }

    /// Selects every placement whose anchor falls inside the marquee rect,
    /// AND every route waypoint inside the rect. The waypoint catch is what
    /// lets the user grab a subcircuit's interior bends so the routes don't
    /// deform when the whole selection is dragged. `additive` (Cmd held at
    /// gesture end) ORs into the existing selection; otherwise the marquee
    /// replaces it.
    private func applyMarquee(screenRect: CGRect, additive: Bool) {
        let worldMin = transform.toWorld(CGPoint(x: screenRect.minX, y: screenRect.minY))
        let worldMax = transform.toWorld(CGPoint(x: screenRect.maxX, y: screenRect.maxY))
        let lo = Point(x: min(worldMin.x, worldMax.x), y: min(worldMin.y, worldMax.y))
        let hi = Point(x: max(worldMin.x, worldMax.x), y: max(worldMin.y, worldMax.y))

        var placementHits: Set<UUID> = []
        for placement in document.circuit.physical.placements {
            guard visible.contains(Layer(plate: placement.layer, depth: placement.depth)) else { continue }
            let p = placement.position
            if p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y {
                placementHits.insert(placement.componentId)
            }
        }
        var waypointHits: Set<RouteWaypointAddress> = []
        for route in document.circuit.physical.routes {
            for (sIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                for (wIdx, wp) in segment.waypoints.enumerated() {
                    let p = wp.position
                    if p.x >= lo.x && p.x <= hi.x && p.y >= lo.y && p.y <= hi.y {
                        waypointHits.insert(RouteWaypointAddress(
                            netId: route.netId, segmentIndex: sIdx, waypointIndex: wIdx
                        ))
                    }
                }
            }
        }

        var next = additive ? selection : PhysicalSelection.none
        next.routeSegment = nil  // marquee select doesn't pair with vertex-edit mode
        next.placements.formUnion(placementHits)
        next.waypoints.formUnion(waypointHits)
        selection = next
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
            } else if !NSEvent.modifierFlags.contains(.command) {
                // Cmd-tap on empty area preserves selection (so the user can
                // Cmd-tap placements to extend a multi-selection without
                // accidentally clearing it). Plain background tap deselects.
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
              let pin = component.footprint(manufacturing).pin(pinKey)
        else { return }
        let world = placement.worldPosition(of: pin)
        // Resistor pins inherit the resistor's depth (resistors are pure
        // tubes — they live on whichever layer the user flipped them to).
        // Transistor and port pins always anchor at depth 0.
        let pinLayer = placement.resolvedLayer(of: pin, on: component)

        switch routingState {
        case .idle:
            // Need a net for this pin. Look it up.
            let ref = PinRef(componentId: componentId, pinKey: pinKey)
            guard let net = document.circuit.logic.nets.first(where: { $0.pins.contains(ref) }) else {
                // Pin not on any net — no route to start. Select the placement instead.
                selection = .placement(componentId)
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

    /// V — drops a cross-silicone via at the cursor, switching to the
    /// opposite plate at depth 0. This is the only kind of via that actually
    /// punches through the silicone sheet sandwiched between the two plates.
    private func dropCrossSiliconeVia() {
        guard case let .routing(_, _, layer, _) = routingState else { return }
        dropVia(toLayer: Layer(plate: layer.plate.opposite, depth: 0))
    }

    /// Digit 0…9 — drops a same-plate vertical via at the cursor, switching
    /// to the chosen depth on the *current* plate. No-op when already on
    /// that depth, or when the chosen depth doesn't exist on the current
    /// plate (i.e. it's ≥ the plate's layer count).
    private func dropSamePlateVia(toDepth depth: Int) {
        guard case let .routing(_, _, layer, _) = routingState else { return }
        guard depth != layer.depth else { return }
        let plateLayerCount = document.circuit.physical.layerCount(for: layer.plate)
        guard depth >= 0, depth < plateLayerCount else { return }
        dropVia(toLayer: Layer(plate: layer.plate, depth: depth))
    }

    /// Underlying via mechanics: commit the in-progress segment with a `.via`
    /// terminator at the cursor, then restart routing from the same XY on
    /// `target` with `startsAtVia = true` so the next commit emits the
    /// matching via on the new segment's first waypoint.
    private func dropVia(toLayer target: Layer) {
        guard case let .routing(netId, wps, layer, startsAtVia) = routingState else { return }
        guard target != layer else { return }
        let cursorWorld = transform.snap(transform.toWorld(mouseLocation), grid: grid)
        guard let last = wps.last else { return }

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

        routingLayer = target
        routingState = .routing(netId: netId, waypoints: [cursorWorld], layer: target, startsAtVia: true)
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
        deleteCurrentSelection()
    }

    /// R rotates each selected placement by 90° in place. Multi-selection
    /// rotates every member independently around its own anchor (rather
    /// than rotating the bounding box around its centroid), which matches
    /// what users typically want when they multi-select to "fix orientation
    /// on a row of parts."
    private func rotateSelection() {
        guard !selection.placements.isEmpty else { return }
        for id in selection.placements {
            guard let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id })
            else { continue }
            let next: Rotation
            switch document.circuit.physical.placements[i].rotation {
            case .r0: next = .r90
            case .r90: next = .r180
            case .r180: next = .r270
            case .r270: next = .r0
            }
            document.circuit.physical.placements[i].rotation = next
        }
    }

    private func flipLayerSelection() {
        guard !selection.placements.isEmpty else { return }
        // Build the cycle order once — T0, T1, …, Tn-1, B0, B1, …, Bm-1.
        // Pure-hole components (resistors are tubes; ports/vents/vacuum
        // sources are edge bores) step one position along this cycle on
        // each F press, so F walks them through every channel layer the
        // board has. Transistors keep the "flip plate" behaviour because
        // their dimple/dome geometry is pinned to the silicone-facing
        // depth-0 layer.
        let cycle = document.circuit.physical.layers(in: .top)
            + document.circuit.physical.layers(in: .bottom)
        for id in selection.placements {
            guard let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id })
            else { continue }
            let placement = document.circuit.physical.placements[i]
            let component = document.circuit.logic.components.first(where: { $0.id == id })
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
        // Resistor pins inherit the resistor's full Layer (plate + depth);
        // transistor / port pins always come in at depth 0. Either way the
        // pin handle uses its layer's palette colour so it reads the same
        // as a route landing on it.
        return LayerPalette.color(for: layer).opacity(0.7)
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
                selection = .placement(id)
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
            // Default layer: bottom for dimple-bearing kinds (transistor,
            // LED) so the viewing/source/drain features land on the top
            // plate; top for everything else.
            let component = document.circuit.logic.components.first(where: { $0.id == id })
            let dimpleKinds: Set<ComponentKind> = [.transistor, .led]
            let defaultPlate: Plate = (component.map { dimpleKinds.contains($0.kind) } ?? false) ? .bottom : .top
            document.circuit.physical.placements.append(
                Placement(componentId: id, position: world, rotation: .r0, layer: defaultPlate)
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
