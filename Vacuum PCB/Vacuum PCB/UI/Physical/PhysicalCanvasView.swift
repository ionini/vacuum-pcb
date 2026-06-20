import SwiftUI
import UniformTypeIdentifiers

/// The main physical 2D editor: board outline, grid, placements, routes,
/// routing preview, pin handles, and keyboard / drop / hit interaction.
struct PhysicalCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: PhysicalSelection
    @Binding var routingState: RoutingState
    @Binding var visible: LayerVisibility
    /// Bottom-to-top paint order of the channel layers, driven by the
    /// drag-reorderable visibility pills. Placements, pin handles, and route
    /// segments are drawn in this order so the layer the user dragged to the
    /// end stacks visually on top of the rest.
    var layerOrder: [Layer]
    @Binding var routingLayer: Layer
    @Binding var routingError: String?
    var showRatsnest: Bool
    /// Whether to overlay the sum-of-Gaussians pressure heatmap from screw
    /// placement. Off by default; toggled from the toolbar popover.
    var showPressureMap: Bool
    /// Gaussian σ (mm) controlling each screw's pressure-influence radius.
    /// Larger values spread the influence further — calibrate against the
    /// stiffness of the actual board+silicone stackup.
    var pressureSigma: Double
    /// Sticky-mode equivalent of holding Cmd at drag start. When on, every
    /// placement drag carries connected route waypoints along with it.
    /// OR'd with `ModifierKeys.commandHeld` in `startPlacementDrag` so the
    /// keyboard path on macOS keeps working independently.
    var dragWithRoutes: Bool
    /// Transient pulse marker dropped when the user clicks a DRC issue with
    /// a focal point. Read-only — DocumentView owns the value and the
    /// auto-clear timer. We re-mount the overlay on each new focus via
    /// `.id(focus.id)` so the animation restarts.
    var issueFocus: DRC.Focus?

    @State private var transform: CanvasTransform = .default
    @State private var mouseLocation: CGPoint = .zero
    @State private var draggingWaypoint: DraggingWaypoint?
    @State private var draggingPlacement: DraggingPlacement?
    /// Click-and-hold disambiguator state. When non-nil, a popover anchored
    /// at `screenPoint` lists every selectable element under that point so
    /// the user can pick through a stack (a placement covering a route, a
    /// route under a via, etc.) — Fusion 360's "select under" pattern.
    @State private var disambiguator: DisambigState?
    /// Whether the user has interacted with zoom/pan since the last fit. If
    /// not, view-size changes re-fit to keep the board centred; once the
    /// user has taken control, size changes leave the transform alone so
    /// resizes don't yank the viewport.
    @State private var userAdjustedView: Bool = false
    /// Accumulator for an in-progress magnify gesture so we can apply
    /// deltas against the transform at gesture start, not against a
    /// running-multiplied baseline that would drift.
    @State private var magnifyBaseline: CanvasTransform?
    /// Magnification value at which the pinch escaped the deadband (see
    /// `magnifyGesture`). nil while we're still ignoring small jitter.
    @State private var zoomOriginMagnification: Double?
    /// Background-drag mode latched at drag start: marquee (Option not held)
    /// or pan (Option held). Decided once so a release after toggling the
    /// modifier mid-drag doesn't flip behaviour at the very end.
    @State private var bgDragMode: BackgroundDragMode = .none
    @State private var panBaseline: CGSize = .zero
    /// Sticky toggle that puts the canvas into pan/zoom-only mode. The
    /// race-fix in `TwoFingerPanCatcher.onMultiTouchBegan` cancels most
    /// stray component drags, but it can't help when finger #1 lands
    /// well before #2 — SwiftUI commits to the drag before any
    /// multi-touch arbitration. Locking the canvas is the bulletproof
    /// fallback: single-finger drags pan instead of moving placements.
    @State private var navigateMode: Bool = false

    enum BackgroundDragMode { case none, marquee, pan }

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
    private var librarySnapshots: [String: CircuitDocument] { document.circuit.librarySnapshots }
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
                Color.canvasBackground
                    .contentShape(Rectangle())
                    .onTapGesture(coordinateSpace: .local) { pt in
                        handleBackgroundTap(at: pt)
                    }
                    // Drag on empty canvas → marquee select. Min-distance 4
                    // gives SwiftUI room to disambiguate from a click.
                    // Masked off in lock mode so a pinch finger that
                    // happens to land on background can't draw a stray
                    // marquee box — the canvas-root `lockPanGesture`
                    // handles single-finger pans there instead.
                    .gesture(marqueeGesture, including: navigateMode ? .none : .gesture)

                gridLines(in: geo.size)
                boardOutline
                if showPressureMap {
                    PressureHeatmapOverlay(
                        document: document.circuit,
                        transform: transform,
                        sigma: pressureSigma
                    )
                }
                subpartExpansions

                RoutesOverlay(
                    document: document.circuit,
                    transform: transform,
                    visible: visible,
                    layerOrder: layerOrder,
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
                if showRatsnest && !visible.isSiliconeSheet {
                    RatsnestOverlay(
                        document: document.circuit,
                        transform: transform,
                        visible: visible
                    )
                }
                if visible.isSiliconeSheet {
                    SiliconeSheetViasOverlay(
                        document: document.circuit,
                        transform: transform,
                        manufacturing: manufacturing
                    )
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

                if let focus = issueFocus, visible.contains(focus.layer) {
                    IssueFocusPing(
                        position: focus.position,
                        transform: transform
                    )
                    .id(focus.id)
                    .allowsHitTesting(false)
                }

                // NSEvent-monitor key catcher. Replaces the hidden-Button
                // approach which would silently lose its shortcut when
                // focus drifted to a non-canvas view.
                KeyEventCatcher(
                    handlers: viaKeyHandlers,
                    commandHandlers: zoomCommandHandlers
                )

                // Right-click catcher overlays the whole canvas. SwiftUI on
                // macOS doesn't surface secondary-button taps natively, so a
                // thin NSView fields rightMouseDown and forwards the location.
                RightClickCatcher { pt in handleRightClick(at: pt) }
                    .allowsHitTesting(true)

                // Scroll-wheel → pan; Cmd+scroll → zoom about cursor.
                // Trackpad two-finger swipes route through the same event
                // type so this covers both input methods.
                ScrollEventCatcher(
                    onPan: { dx, dy in
                        transform = CanvasTransform(
                            ptsPerMm: transform.ptsPerMm,
                            offset: CGSize(
                                width: transform.offset.width  + Double(dx),
                                height: transform.offset.height + Double(dy)
                            )
                        )
                        userAdjustedView = true
                    },
                    onZoom: { factor, cursor in
                        zoomBy(factor, cursor: cursor)
                    }
                )
                .allowsHitTesting(true)

                // iPad: two-finger drag pans, leaving one-finger drag for
                // marquee / component move / pin route. macOS pan is
                // handled by ScrollEventCatcher and Option-drag; this
                // catcher no-ops there.
                TwoFingerPanCatcher(
                    onPan: { dx, dy in
                        transform = CanvasTransform(
                            ptsPerMm: transform.ptsPerMm,
                            offset: CGSize(
                                width: transform.offset.width  + Double(dx),
                                height: transform.offset.height + Double(dy)
                            )
                        )
                        userAdjustedView = true
                    },
                    onMultiTouchBegan: {
                        // Second finger landed — drop any single-finger
                        // drag the first finger may have started so
                        // pan/pinch wins cleanly. The placement-drag
                        // `.onEnded` later sees `draggingPlacement == nil`
                        // and bails out without committing a move.
                        draggingPlacement = nil
                        draggingWaypoint = nil
                        marquee = nil
                        bgDragMode = .none
                    }
                )

                // Zoom controls floating in the top-right corner. Sits on
                // top of all canvas content; ignores hits otherwise.
                ZoomToolbar(
                    zoomPercent: zoomPercent(viewSize: geo.size),
                    onZoomOut: { zoomBy(1 / 1.25, viewSize: geo.size) },
                    onFit: { recomputeTransform(viewSize: geo.size); userAdjustedView = false },
                    onZoomIn: { zoomBy(1.25, viewSize: geo.size) },
                    isLocked: navigateMode,
                    onToggleLock: {
                        navigateMode.toggle()
                        // Drop in-flight gesture state so the mode flip
                        // doesn't leave a half-applied drag behind.
                        draggingPlacement = nil
                        draggingWaypoint = nil
                        marquee = nil
                        bgDragMode = .none
                        if navigateMode { routingState = .idle }
                    }
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }
            .environment(\.canvasLocked, navigateMode)
            .coordinateSpace(name: "canvas")
            .clipped()
            .background(Color.canvasBackground)
            .onContinuousHover { phase in
                if case .active(let p) = phase { mouseLocation = p }
            }
            // Open-hand cursor whenever the pointer is over a draggable
            // object (placement, pin, via, or route). The discrete hit
            // targets sit above this view, but pointer-style resolution
            // picks the innermost match — so a single root-level style keyed
            // on the unified hit-test reads correctly without instrumenting
            // every child. macOS-only: `pointerStyle(_:)` isn't in the
            // iOS/iPadOS SDK, and there's no pointer to style on touch.
            #if os(macOS)
            .pointerStyle(pointerOverDraggable ? .grabIdle : nil)
            #endif
            .gesture(magnifyGesture(viewSize: geo.size))
            // Lock-mode pan. Child drag gestures (placement move, pin
            // drag-to-route, waypoint drag) read `\.canvasLocked` and
            // mask to `.none` when locked, so this is the only
            // DragGesture left in the tree. `.subviews` mask when
            // unlocked deactivates this gesture so editing works
            // normally.
            .highPriorityGesture(
                lockPanGesture,
                including: navigateMode ? .all : .subviews
            )
            // Click-and-hold over any stacked content (placement on top of a
            // route, route under a via, etc.) opens a SwiftUI popover listing
            // every selectable item at the cursor. `.simultaneousGesture` so
            // plain clicks, drags, and pin taps still work; the long-press
            // only wins when the user actively holds without moving.
            .simultaneousGesture(disambigGesture)
            // Anchor for the popover. `.position()` doesn't change the source
            // rect the popover reads — SwiftUI calculates it from the modified
            // view's intrinsic bounds, ignoring the position-induced offset,
            // which is what pinned the menu to the canvas's right edge.
            // Instead, attach the popover to a transparent overlay that
            // covers the whole canvas and compute the press location as a
            // UnitPoint via the inner GeometryReader. The `attachmentAnchor`
            // recomputes whenever `disambiguator` changes.
            .overlay {
                GeometryReader { overlayGeo in
                    let anchor: UnitPoint = disambiguator.map { d in
                        UnitPoint(
                            x: d.screenPoint.x / max(1, overlayGeo.size.width),
                            y: d.screenPoint.y / max(1, overlayGeo.size.height)
                        )
                    } ?? .center
                    Color.clear
                        .allowsHitTesting(false)
                        .popover(
                            isPresented: Binding(
                                get: { disambiguator != nil },
                                set: { if !$0 { disambiguator = nil } }
                            ),
                            attachmentAnchor: .point(anchor),
                            arrowEdge: .top
                        ) {
                            if let d = disambiguator {
                                DisambigPopover(
                                    candidates: d.candidates,
                                    dismiss: { disambiguator = nil }
                                )
                            }
                        }
                }
            }
            .onAppear {
                lastViewSize = geo.size
                recomputeTransform(viewSize: geo.size)
            }
            .onChange(of: geo.size) { _, new in
                lastViewSize = new
                // First-time fit only — once the user has zoomed/panned,
                // resizing the window shouldn't blow away their viewport.
                if !userAdjustedView { recomputeTransform(viewSize: new) }
            }
            .onDrop(of: [.text], delegate: ParkingDropDelegate(
                document: $document,
                transform: { transform },
                gridMm: grid,
                routingLayer: routingLayer,
                selection: $selection
            ))
        }
    }

    /// Zoom shortcuts bound to Cmd+key — kept separate from via/route keys
    /// so plain `0` still drops a via and ⌘0 fits to view.
    private var zoomCommandHandlers: [UInt16: () -> Void] {
        [
            KeyCodes.equals: { zoomBy(1.25, cursor: mouseLocation) },
            KeyCodes.minus: { zoomBy(1 / 1.25, cursor: mouseLocation) },
            KeyCodes.zero: { userAdjustedView = false; recomputeTransform(viewSize: lastViewSize) },
        ]
    }

    /// View size cached during gesture passes so the keyboard-driven Fit
    /// can recompute against a real rect. Defaults to a safe sentinel until
    /// the first hover/layout pass populates it.
    @State private var lastViewSize: CGSize = CGSize(width: 800, height: 600)

    private func zoomPercent(viewSize: CGSize) -> Double {
        // Express the current ptsPerMm as a fraction of the fit-to-view
        // baseline so 100% always means "exactly fits". A user who hits +
        // a few times and then Fit gets the readout back to 100%.
        let fit = CanvasTransform.fit(
            rect: document.circuit.physical.boardOutline,
            in: viewSize, margin: 36
        )
        guard fit.ptsPerMm > 0 else { return 1 }
        return transform.ptsPerMm / fit.ptsPerMm
    }

    /// Zooms about a screen-space anchor point. World coord under `cursor`
    /// stays fixed: `new offset = cursor - (cursor - old offset) * factor`.
    private func zoomBy(_ factor: Double, viewSize: CGSize) {
        let anchor = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        zoomBy(factor, cursor: anchor)
    }

    private func zoomBy(_ factor: Double, cursor: CGPoint) {
        let minScale = 0.5, maxScale = 200.0
        let newScale = max(minScale, min(maxScale, transform.ptsPerMm * factor))
        let actualFactor = newScale / transform.ptsPerMm
        guard abs(actualFactor - 1) > 0.0001 else { return }
        let newOffsetX = Double(cursor.x) - (Double(cursor.x) - transform.offset.width)  * actualFactor
        let newOffsetY = Double(cursor.y) - (Double(cursor.y) - transform.offset.height) * actualFactor
        transform = CanvasTransform(
            ptsPerMm: newScale,
            offset: CGSize(width: newOffsetX, height: newOffsetY)
        )
        userAdjustedView = true
    }

    /// Active only when `navigateMode` is on. Single-finger drag
    /// anywhere on the canvas pans the viewport, beating every child
    /// drag gesture (placement move, pin drag-to-route, waypoint drag)
    /// via `.highPriorityGesture` on the canvas root. `.local` here is
    /// the canvas's outer chain — already in window points — so the
    /// translation goes straight onto `transform.offset` without any
    /// `ptsPerMm` rescale.
    private var lockPanGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode != .pan {
                    bgDragMode = .pan
                    panBaseline = transform.offset
                }
                transform = CanvasTransform(
                    ptsPerMm: transform.ptsPerMm,
                    offset: CGSize(
                        width: panBaseline.width  + value.translation.width,
                        height: panBaseline.height + value.translation.height
                    )
                )
                userAdjustedView = true
            }
            .onEnded { _ in
                bgDragMode = .none
            }
    }

    /// Trackpad pinch. The magnification value is cumulative within a
    /// single gesture, so we capture a baseline at gesture start and apply
    /// the delta against it each tick — otherwise repeated pinches would
    /// drift away from the user's intended scale.
    ///
    /// `MagnifyGesture` on iPad is extremely sensitive — natural finger
    /// jitter while panning produces sub-pt distance changes that the
    /// system reports as 1.02–1.05 magnifications and the canvas would
    /// otherwise honour, hijacking the pan. We sit in a deadband until
    /// the user moves their fingers apart (or together) by at least
    /// `threshold` percent, and once we cross it the zoom is computed
    /// relative to that crossing point so engagement is smooth instead
    /// of snapping.
    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseline == nil {
                    magnifyBaseline = transform
                    zoomOriginMagnification = nil
                }
                guard let base = magnifyBaseline else { return }
                let threshold = InputPlatform.isTouch ? 0.15 : 0.04
                let origin: Double
                if let z = zoomOriginMagnification {
                    origin = z
                } else if abs(value.magnification - 1.0) < threshold {
                    return
                } else {
                    zoomOriginMagnification = value.magnification
                    origin = value.magnification
                }
                let cursor = mouseLocation == .zero
                    ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                    : mouseLocation
                let factor = max(0.05, value.magnification / origin)
                let newScale = max(0.5, min(200.0, base.ptsPerMm * factor))
                let nx = Double(cursor.x) - (Double(cursor.x) - base.offset.width)  * (newScale / base.ptsPerMm)
                let ny = Double(cursor.y) - (Double(cursor.y) - base.offset.height) * (newScale / base.ptsPerMm)
                transform = CanvasTransform(
                    ptsPerMm: newScale,
                    offset: CGSize(width: nx, height: ny)
                )
                userAdjustedView = true
                lastViewSize = viewSize
            }
            .onEnded { _ in
                magnifyBaseline = nil
                zoomOriginMagnification = nil
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
                let b = transform.toScreen(Point(x: outline.maxX, y: y))
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
                        rootManufacturing: manufacturing,
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

    /// Index of `layer` in the user's paint order; layers not listed sort
    /// last so they paint on top rather than disappearing.
    private func paintRank(_ layer: Layer) -> Int {
        layerOrder.firstIndex(of: layer) ?? layerOrder.count
    }

    /// Placements sorted by their layer's paint order (lower rank = painted
    /// first = underneath). Ties fall back to the document's array order via
    /// the captured offset, so component identity stays stable across
    /// reorders and SwiftUI doesn't tear down views needlessly.
    private var placementsInPaintOrder: [Placement] {
        document.circuit.physical.placements.enumerated()
            .sorted { a, b in
                let ra = paintRank(Layer(plate: a.element.layer, depth: a.element.depth))
                let rb = paintRank(Layer(plate: b.element.layer, depth: b.element.depth))
                return ra != rb ? ra < rb : a.offset < b.offset
            }
            .map(\.element)
    }

    private var placementBodies: some View {
        ZStack {
            ForEach(placementsInPaintOrder, id: \.componentId) { placement in
                if let component = component(for: placement.componentId),
                   visible.shows(componentKind: component.kind,
                                 on: Layer(plate: placement.layer, depth: placement.depth)) {
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
            ForEach(placementsInPaintOrder, id: \.componentId) { placement in
                if let component = component(for: placement.componentId),
                   visible.shows(componentKind: component.kind,
                                 on: Layer(plate: placement.layer, depth: placement.depth)) {
                    let pos = hitCenter(for: placement, component: component)
                    let size = hitSize(for: component, rotation: placement.rotation)
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
                        // Drag is the destructive op (move). In lock mode
                        // the canvas-root pan gesture takes over; we mask
                        // this one to `.none` so it can't snag touches.
                        .gesture(
                            placementDragGesture(placement),
                            including: navigateMode ? .none : .gesture
                        )
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
        let b = component.footprint(manufacturing, snapshots: librarySnapshots).boundingRect
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
        if !ModifierKeys.commandHeld,
           let hit = routeSegmentHit(at: pt) {
            selection = .routeSegment(netId: hit.netId, segmentIndex: hit.segmentIndex)
            routingState = .idle
            return
        }
        if ModifierKeys.commandHeld {
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
        // 2 pt is right for a precise trackpad cursor but turns finger
        // micro-twitches into accidental drags on iPad — raise the
        // threshold there.
        let minDistance: Double = InputPlatform.isTouch ? 6 : 2
        return DragGesture(minimumDistance: minDistance, coordinateSpace: .global)
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
                // Screws are mechanical-only — no pins, no routes snap to
                // them — so when the drag set is *all* screws and Cmd is
                // held at release, skip the grid snap. Cmd's usual meaning
                // (drag with attached routes) is a no-op on screws anyway.
                let allScrews = drag.originals.keys.allSatisfy { id in
                    document.circuit.logic.components.first(where: { $0.id == id })?.kind == .screw
                }
                let cmdHeld = ModifierKeys.commandHeld
                let delta: Point
                if allScrews && cmdHeld {
                    delta = raw
                } else {
                    delta = Point(
                        x: (raw.x / grid).rounded() * grid,
                        y: (raw.y / grid).rounded() * grid
                    )
                }
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
        // Either the per-drag modifier (Cmd on macOS) or the sticky
        // toolbar toggle opt in to the rubber-band carry. They compose so
        // a power user on macOS who's also flipped the toggle still works.
        let withRoutes = ModifierKeys.commandHeld || dragWithRoutes
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
            for pin in component.footprint(manufacturing, snapshots: librarySnapshots).pins {
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

    private func hitSize(for c: Component, rotation: Rotation) -> CGSize {
        // Footprint exclusion-rect dimensions in pts, padded so small parts
        // stay easy to grab. The arrowhead glyph for ports / rails extends
        // well past the pin anchor — and the tip is exactly what users aim
        // at — so give those kinds a generous minimum target. On iPad the
        // pin handle (~26 pt hit zone) sits on top of the placement, so
        // the body's own target has to be considerably bigger than the
        // pin's to leave finger-sized slack around the glyph.
        let bounds = c.footprint(manufacturing, snapshots: librarySnapshots).boundingRect
        // The hit rectangle is screen-axis-aligned, but the body is drawn
        // rotated — so a quarter-turn swaps the footprint's width and height
        // on screen. Connectors are authored as a long thin row along local
        // Y; on the north / south edges (r90 / r270) that row runs
        // horizontally, and without this swap the hit zone collapses to a
        // narrow strip down the connector's centre.
        var bw = bounds.size.width, bh = bounds.size.height
        if rotation == .r90 || rotation == .r270 { swap(&bw, &bh) }
        let isArrowLike: Bool = (c.kind == .port || c.kind == .vacuumSource || c.kind == .atmVent)
        let minSize: Double = {
            if InputPlatform.isTouch { return isArrowLike ? 88 : 56 }
            return isArrowLike ? 60 : 40
        }()
        let pad: Double = InputPlatform.isTouch ? 20 : 12
        let w = max(minSize, bw * transform.ptsPerMm + pad)
        let h = max(minSize, bh * transform.ptsPerMm + pad)
        return CGSize(width: w, height: h)
    }

    // MARK: - Pin handles

    private var pinHandles: some View {
        ZStack {
            ForEach(placementsInPaintOrder, id: \.componentId) { placement in
                if let component = component(for: placement.componentId) {
                    ForEach(component.footprint(manufacturing, snapshots: librarySnapshots).pins, id: \.key) { pin in
                        // Sub-part boundary pins carry their library-internal
                        // Layer in `FootprintPin.absoluteLayer`, so the same
                        // resolver call handles both primitives and sub-part
                        // instance pins.
                        let pinLayer = placement.resolvedLayer(of: pin, on: component)
                        if visible.contains(pinLayer) {
                            let world = placement.worldPosition(of: pin)
                            let screen = transform.toScreen(world)
                            let id = placement.componentId
                            let key = pin.key
                            PhysicalPinHandle(
                                pinKey: pinDisplayLabel(component: component, key: pin.key),
                                layer: pinLayer,
                                isFirstOfRouting: isFirstRoutingPin(componentId: id, key: key),
                                onTap: { handlePinTap(componentId: id, pinKey: key) },
                                onDragChanged: { canvasPt in
                                    handlePinDragChanged(componentId: id, pinKey: key, at: canvasPt)
                                },
                                onDragEnded: { canvasPt in
                                    handlePinDragEnded(componentId: id, pinKey: key, at: canvasPt)
                                }
                            )
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
        if let pin = component.subpartBoundaryPin(key: key, snapshots: document.circuit.librarySnapshots) {
            return pin.label
        }
        if component.kind == .connector {
            return component.connectorPinName(key)
        }
        return key
    }

    private func isFirstRoutingPin(componentId: UUID, key: String) -> Bool {
        guard case let .routing(_, waypoints, _, _) = routingState,
              let firstWP = waypoints.first,
              let placement = document.circuit.physical.placements.first(where: { $0.componentId == componentId }),
              let component = component(for: componentId),
              let pin = component.footprint(manufacturing, snapshots: librarySnapshots).pin(key)
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
                    .gesture(
                        handleDragGesture(netId: seg.netId, segIdx: seg.segmentIndex, idx: i, originals: originals),
                        including: navigateMode ? .none : .gesture
                    )
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
        let minDistance: Double = InputPlatform.isTouch ? 4 : 1
        return DragGesture(minimumDistance: minDistance, coordinateSpace: .global)
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
        // Match the handle's hit area (~22pt square → ~11pt radius on
        // macOS, 28pt → ~14pt radius on iPad — see WaypointHandle).
        let threshold: Double = InputPlatform.isTouch ? 14 : 11
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

    /// Bulk-delete everything in the current selection. Lives in
    /// `PhysicalActions` so the inspector's contextual Delete button can
    /// invoke the exact same path as the ⌫ shortcut.
    private func deleteCurrentSelection() {
        PhysicalActions.delete(document: &document, selection: &selection)
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
        // Background drag does two things depending on modifier at start:
        // plain → marquee select, Option held → pan the viewport. The mode
        // latches on first tick so a release after toggling Option mid-drag
        // doesn't flip behaviour at the last moment.
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode == .none {
                    if ModifierKeys.optionHeld {
                        bgDragMode = .pan
                        panBaseline = transform.offset
                    } else {
                        bgDragMode = .marquee
                    }
                }
                switch bgDragMode {
                case .pan:
                    transform = CanvasTransform(
                        ptsPerMm: transform.ptsPerMm,
                        offset: CGSize(
                            width: panBaseline.width  + value.translation.width,
                            height: panBaseline.height + value.translation.height
                        )
                    )
                    userAdjustedView = true
                case .marquee, .none:
                    marquee = MarqueeRect(
                        startScreen: value.startLocation,
                        currentScreen: value.location
                    )
                }
            }
            .onEnded { value in
                defer { marquee = nil; bgDragMode = .none }
                guard bgDragMode == .marquee else { return }
                let rect = MarqueeRect(
                    startScreen: value.startLocation,
                    currentScreen: value.location
                ).rect
                // Tiny rectangles (sub-grid) are likely fumbled clicks — treat
                // as a no-op rather than wiping the selection silently.
                guard rect.width > 2 || rect.height > 2 else { return }
                applyMarquee(screenRect: rect, additive: ModifierKeys.commandHeld)
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
            guard let kind = document.circuit.logic.components
                .first(where: { $0.id == placement.componentId })?.kind
            else { continue }
            // Screws aren't bound to any channel layer; let them marquee
            // through the layer filter so they can be selected even when
            // both plates' chips are off. Silicone-sheet mode extends the
            // same courtesy to transistors (their gate is on the sheet).
            guard visible.shows(componentKind: kind,
                                on: Layer(plate: placement.layer, depth: placement.depth))
            else { continue }
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
            // Vias on visible segments are clickable so the user can pick up a
            // route at one — handy when a mid-route segment got deleted and
            // its sibling via is now stranded.
            if let via = viaAtTap(at: pt) {
                routingLayer = via.layer
                routingState = .routing(
                    netId: via.netId, waypoints: [via.position],
                    layer: via.layer, startsAtVia: true
                )
                selection = .none
                routingError = nil
                return
            }
            // Hit-test route segments before deselecting. RoutesOverlay is a
            // Canvas (cheap render, no per-segment hit testing), so we test
            // here by computing point-to-polyline distance.
            if let hit = routeSegmentHit(at: pt) {
                selection = .routeSegment(netId: hit.netId, segmentIndex: hit.segmentIndex)
            } else if !ModifierKeys.commandHeld {
                // Cmd-tap on empty area preserves selection (so the user can
                // Cmd-tap placements to extend a multi-selection without
                // accidentally clearing it). Plain background tap deselects.
                selection = .none
            }
        case .routing(let netId, var wps, let layer, let startsAtVia):
            // Click an existing via to close the in-progress route into it —
            // mirrors clicking a pin, but the closing waypoint is marked
            // `.via` so the via XY stays a via in both segments.
            if let via = viaAtTap(at: pt) {
                if let first = wps.first, approximatelyEqual(first, via.position), wps.count == 1 {
                    routingState = .idle
                    return
                }
                guard via.netId == netId else {
                    routingError = "Via is on a different net — connections must stay within a single net."
                    routingState = .idle
                    return
                }
                var finalPath = wps
                if let last = finalPath.last {
                    let elbow = elbow(from: last, to: via.position)
                    if !approximatelyEqual(elbow, last) { finalPath.append(elbow) }
                    if !approximatelyEqual(via.position, finalPath.last ?? last) {
                        finalPath.append(via.position)
                    }
                }
                appendRouteSegment(
                    netId: netId, points: finalPath, layer: layer,
                    startsAtVia: startsAtVia, endsAtVia: true
                )
                routingState = .idle
                return
            }
            let world = transform.snap(transform.toWorld(pt), grid: grid)
            guard let last = wps.last else { return }
            let elbow = elbow(from: last, to: world)
            if !approximatelyEqual(elbow, last) { wps.append(elbow) }
            if !approximatelyEqual(world, wps.last ?? last) { wps.append(world) }
            routingState = .routing(netId: netId, waypoints: wps, layer: layer, startsAtVia: startsAtVia)
        }
    }

    /// Hit-tests via waypoints on visible segments. Returns the nearest via
    /// within the dot's outer radius, so clicking the via dot wins over the
    /// underlying segment polyline.
    private func viaAtTap(at pt: CGPoint) -> (netId: UUID, layer: Layer, position: Point)? {
        // Mirrors ViasOverlay's outer-radius computation plus a small slop so
        // a click on the dot's rim still hits.
        let radius = max(8, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        let radiusSq = radius * radius
        var best: (netId: UUID, layer: Layer, position: Point, distSq: Double)?
        for route in document.circuit.physical.routes {
            for segment in route.segments {
                guard visible.contains(segment.layer) else { continue }
                for wp in segment.waypoints where wp.kind == .via {
                    let screen = transform.toScreen(wp.position)
                    let dx = Double(pt.x - screen.x)
                    let dy = Double(pt.y - screen.y)
                    let d2 = dx * dx + dy * dy
                    if d2 <= radiusSq, d2 < (best?.distSq ?? .greatestFiniteMagnitude) {
                        best = (route.netId, segment.layer, wp.position, d2)
                    }
                }
            }
        }
        return best.map { ($0.netId, $0.layer, $0.position) }
    }

    /// Returns the closest visible route segment whose polyline passes within
    /// the channel-stroke width of `pt` (screen pts). Nil if nothing is close.
    private func routeSegmentHit(at pt: CGPoint) -> (netId: UUID, segmentIndex: Int)? {
        // Match RoutesOverlay's stroke width and add a small slop so a click
        // near the edge of the rendered channel still hits. Fingers are
        // less precise than a cursor, so the touch floor is a few pt wider.
        let channelStroke = max(1.5, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        let slop: Double = InputPlatform.isTouch ? 5.0 : 3.0
        let floor: Double = InputPlatform.isTouch ? 10.0 : 6.0
        let threshold = max(floor, channelStroke / 2 + slop)
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

    /// First tick of a drag that started on a pin: begin routing from this
    /// pin (if idle) and update `mouseLocation` so `RoutingPreviewOverlay`
    /// follows the finger. Routing-already-in-progress drags just update
    /// the cursor without re-tapping the pin.
    private func handlePinDragChanged(componentId: UUID, pinKey: String, at canvasPt: CGPoint) {
        if !routingState.inProgress {
            handlePinTap(componentId: componentId, pinKey: pinKey)
        }
        mouseLocation = canvasPt
    }

    /// Release on another pin commits the route to it; release in empty
    /// space drops a waypoint at the release point so the user can keep
    /// extending with subsequent taps. Mirrors the click-then-click flow,
    /// just driven by a single drag instead.
    private func handlePinDragEnded(componentId: UUID, pinKey: String, at canvasPt: CGPoint) {
        if let target = pinHit(at: canvasPt) {
            handlePinTap(componentId: target.componentId, pinKey: target.pinKey)
            return
        }
        // No pin under the release: treat it the same as a tap on empty
        // canvas at that point (extends the in-progress route there). Skip
        // if routing isn't actually in flight — that can happen when the
        // drag was too small to start one but somehow still reached
        // onEnded with onChanged never firing.
        if routingState.inProgress {
            handleBackgroundTap(at: canvasPt)
        }
    }

    /// Nearest visible pin under a canvas-local point, within a forgiving
    /// touch-friendly radius. Mirrors the same world→screen projection the
    /// renderer uses so the user's eye and the hit test stay aligned.
    private func pinHit(at canvasPt: CGPoint) -> (componentId: UUID, pinKey: String)? {
        let radius: Double = InputPlatform.isTouch ? 26 : 18
        let radiusSq = radius * radius
        var best: (componentId: UUID, pinKey: String, distSq: Double)?
        for placement in document.circuit.physical.placements {
            guard let component = component(for: placement.componentId) else { continue }
            for pin in component.footprint(manufacturing, snapshots: librarySnapshots).pins {
                let pinLayer = placement.resolvedLayer(of: pin, on: component)
                guard visible.contains(pinLayer) else { continue }
                let world = placement.worldPosition(of: pin)
                let screen = transform.toScreen(world)
                let dx = Double(canvasPt.x - screen.x)
                let dy = Double(canvasPt.y - screen.y)
                let d2 = dx * dx + dy * dy
                if d2 <= radiusSq, d2 < (best?.distSq ?? .greatestFiniteMagnitude) {
                    best = (placement.componentId, pin.key, d2)
                }
            }
        }
        return best.map { ($0.componentId, $0.pinKey) }
    }

    /// True when `pt` (screen-space) lands on any placement's drag hit rect.
    /// Cheap early-out variant of the placement loop in
    /// `collectDisambigCandidates`, used to drive the hover cursor.
    private func placementAtPoint(_ pt: CGPoint) -> Bool {
        for placement in document.circuit.physical.placements {
            guard let component = component(for: placement.componentId),
                  visible.shows(componentKind: component.kind,
                                on: Layer(plate: placement.layer, depth: placement.depth))
            else { continue }
            let centre = hitCenter(for: placement, component: component)
            let size = hitSize(for: component, rotation: placement.rotation)
            let rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                              width: size.width, height: size.height)
            if rect.contains(pt) { return true }
        }
        return false
    }

    /// Whether the pointer is currently over something the user can grab and
    /// drag — a placement, a pin, a via, or a route segment. Drives the
    /// open-hand cursor so movable objects read as movable on hover. Skipped
    /// while panning (lock mode) or routing, where a drag means something
    /// else and the default cursor is correct.
    private var pointerOverDraggable: Bool {
        guard !navigateMode, !routingState.inProgress, mouseLocation != .zero else { return false }
        let pt = mouseLocation
        return pinHit(at: pt) != nil
            || viaAtTap(at: pt) != nil
            || placementAtPoint(pt)
            || routeSegmentHit(at: pt) != nil
    }

    private func handlePinTap(componentId: UUID, pinKey: String) {
        guard let placement = document.circuit.physical.placements.first(where: { $0.componentId == componentId }),
              let component = component(for: componentId),
              let pin = component.footprint(manufacturing, snapshots: librarySnapshots).pin(pinKey)
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

    private func appendRouteSegment(
        netId: UUID, points: [Point], layer: Layer,
        startsAtVia: Bool, endsAtVia: Bool = false
    ) {
        guard points.count >= 2 else { return }
        let lastIdx = points.count - 1
        let waypoints = points.enumerated().map { i, p -> Waypoint in
            let kind: WaypointKind = {
                if i == 0, startsAtVia { return .via }
                if i == lastIdx, endsAtVia { return .via }
                return .point
            }()
            return Waypoint(position: p, kind: kind)
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
        let component = document.circuit.logic.components.first(where: { $0.id == componentId })
        if component?.kind == .connector {
            applyConnectorEdgeSnap(placementIndex: i, component: component!, world: position)
        } else {
            document.circuit.physical.placements[i].position = position
        }
    }

    /// Snap a connector's drag/drop destination to the nearest plate edge.
    /// Thin wrapper over `PhysicalActions.snapConnector` so the in-view
    /// drag handler and the parking-lot drop delegate share one path.
    private func applyConnectorEdgeSnap(placementIndex i: Int, component: Component, world: Point) {
        PhysicalActions.snapConnector(
            in: &document.circuit, placementIndex: i,
            component: component, world: world
        )
    }

    private func deleteSelection() {
        deleteCurrentSelection()
    }

    private func rotateSelection() {
        PhysicalActions.rotate(document: &document, selection: selection)
    }

    private func flipLayerSelection() {
        PhysicalActions.flipLayer(document: &document, selection: selection)
    }

    // MARK: - Disambiguator (click-and-hold)

    /// Long-press fires after ~0.45 s of holding the cursor still. We snapshot
    /// the current `mouseLocation` (kept up to date by `onContinuousHover`)
    /// because LongPressGesture itself doesn't surface the press location.
    /// Suppressed while a route is in progress — the user's next click is
    /// meant to extend that route, not pop a menu.
    private var disambigGesture: some Gesture {
        // Sequence a zero-distance drag after the long press purely to recover
        // the press location. `LongPressGesture` doesn't report it, and on pure
        // touch there's no hover keeping `mouseLocation` current — so without
        // this the menu never opened on an iPad without a pointer.
        // `.named("canvas")` is the space `mouseLocation` and
        // `collectDisambigCandidates` already work in.
        LongPressGesture(minimumDuration: 0.45, maximumDistance: 6)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("canvas")))
            .onEnded { value in
                guard !routingState.inProgress else { return }
                let pt: CGPoint
                if case .second(_, let drag?) = value {
                    pt = drag.location            // touch or pointer: actual press point
                } else if mouseLocation != .zero {
                    pt = mouseLocation            // fallback to last hover
                } else {
                    return
                }
                let candidates = collectDisambigCandidates(at: pt)
                guard !candidates.isEmpty else { return }
                disambiguator = DisambigState(screenPoint: pt, candidates: candidates)
            }
    }

    /// Enumerates every selectable item under `pt` (screen-space). Order is
    /// roughly visual z: vias (smallest, on top), then route segments by
    /// layer, then placements. Each entry knows how to commit its own
    /// selection so the popover doesn't need a dispatch table on the parent.
    private func collectDisambigCandidates(at pt: CGPoint) -> [DisambigCandidate] {
        var out: [DisambigCandidate] = []

        // --- Vias ---
        // Mirror viaAtTap's outer-radius tolerance, but collect *all* hits
        // rather than the closest one. Dedup paired vias by (netId, XY) so a
        // single via doesn't appear twice (it's stored on each twin segment).
        let viaRadius = max(8, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        let viaRadiusSq = viaRadius * viaRadius
        struct ViaHit: Hashable { let netId: UUID; let x: Double; let y: Double }
        var viaSeen: Set<ViaHit> = []
        for route in document.circuit.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                for wp in segment.waypoints where wp.kind == .via {
                    let screen = transform.toScreen(wp.position)
                    let dx = Double(pt.x - screen.x), dy = Double(pt.y - screen.y)
                    guard dx * dx + dy * dy <= viaRadiusSq else { continue }
                    let key = ViaHit(
                        netId: route.netId,
                        x: (wp.position.x / 0.05).rounded() * 0.05,
                        y: (wp.position.y / 0.05).rounded() * 0.05
                    )
                    if viaSeen.contains(key) { continue }
                    viaSeen.insert(key)
                    let netLabel = netLabel(for: route.netId)
                    let label = "Via on \(netLabel) (\(segment.layer.uiLabel))"
                    out.append(DisambigCandidate(
                        label: label,
                        systemImage: "smallcircle.filled.circle",
                        color: LayerPalette.color(for: segment.layer),
                        apply: {
                            selection = .routeSegment(netId: route.netId, segmentIndex: segIdx)
                            routingState = .idle
                        }
                    ))
                }
            }
        }

        // --- Route segments ---
        // Same channel-stroke + 3 pt tolerance as routeSegmentHit, but
        // collecting every distinct (netId, segmentIndex) whose polyline
        // passes within range.
        let channelStroke = max(1.5, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        let routeThreshold = max(6.0, channelStroke / 2 + 3.0)
        struct RouteSegmentKey: Hashable { let netId: UUID; let segmentIndex: Int }
        var seenSegments: Set<RouteSegmentKey> = []
        for route in document.circuit.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                let key = RouteSegmentKey(netId: route.netId, segmentIndex: segIdx)
                if seenSegments.contains(key) { continue }
                let pts = segment.waypoints.map { transform.toScreen($0.position) }
                guard pts.count >= 2 else { continue }
                var hit = false
                for i in 0..<(pts.count - 1) {
                    if distanceFromPoint(pt, toSegmentFrom: pts[i], to: pts[i + 1]) <= routeThreshold {
                        hit = true; break
                    }
                }
                guard hit else { continue }
                seenSegments.insert(key)
                let netLabel = netLabel(for: route.netId)
                out.append(DisambigCandidate(
                    label: "Route \(netLabel) (\(segment.layer.uiLabel))",
                    systemImage: "scribble.variable",
                    color: LayerPalette.color(for: segment.layer),
                    apply: {
                        selection = .routeSegment(netId: route.netId, segmentIndex: segIdx)
                        routingState = .idle
                    }
                ))
            }
        }

        // --- Route waypoints (interior bends): remove ---
        // The touch/long-press equivalent of right-clicking a bend handle on
        // macOS. Endpoints (on pins) and vias are skipped — vias have their own
        // entry above, and removing an endpoint would silently shorten the
        // route. Threshold matches the handle's hit area.
        let removeThreshold: Double = InputPlatform.isTouch ? 14 : 11
        for route in document.circuit.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                let n = segment.waypoints.count
                for (wIdx, wp) in segment.waypoints.enumerated() {
                    guard wIdx > 0, wIdx < n - 1, wp.kind != .via else { continue }
                    let screen = transform.toScreen(wp.position)
                    let d = hypot(Double(pt.x - screen.x), Double(pt.y - screen.y))
                    guard d <= removeThreshold else { continue }
                    out.append(DisambigCandidate(
                        label: "Remove point (\(netLabel(for: route.netId)))",
                        systemImage: "minus.circle",
                        color: LayerPalette.color(for: segment.layer),
                        apply: {
                            deleteWaypoint(netId: route.netId, segIdx: segIdx, waypointIndex: wIdx)
                            selection = .routeSegment(netId: route.netId, segmentIndex: segIdx)
                        }
                    ))
                }
            }
        }

        // --- Route segment: add a point here ---
        // Offered whenever the press is on a route (a segment was hit above).
        // `insertWaypointFromRightClick` re-finds the nearest segment and drops
        // a grid-snapped bend at the projected point.
        if !seenSegments.isEmpty {
            out.append(DisambigCandidate(
                label: "Add point here",
                systemImage: "plus.circle",
                color: .accentColor,
                apply: { insertWaypointFromRightClick(at: pt) }
            ))
        }

        // --- Placements ---
        // Walk the same hit-rect test the placement hit targets use, but
        // accept any placement whose rect covers `pt` — not just the nearest.
        // Screws and silicone-sheet-mode transistors are allowed through the
        // visibility filter on the canvas itself; mirror that here so the
        // user can still pick a screw under a route in any view mode.
        for placement in document.circuit.physical.placements {
            guard let component = component(for: placement.componentId) else { continue }
            guard visible.shows(componentKind: component.kind,
                                on: Layer(plate: placement.layer, depth: placement.depth))
            else { continue }
            let centre = hitCenter(for: placement, component: component)
            let size = hitSize(for: component, rotation: placement.rotation)
            let rect = CGRect(
                x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                width: size.width, height: size.height
            )
            guard rect.contains(pt) else { continue }
            let id = placement.componentId
            out.append(DisambigCandidate(
                label: "\(component.label) (\(componentKindLabel(component.kind)))",
                systemImage: componentSystemImage(component.kind),
                color: LayerPalette.color(for: Layer(plate: placement.layer, depth: placement.depth)),
                apply: {
                    selection = .placement(id)
                    routingState = .idle
                }
            ))
        }

        return out
    }

    private func netLabel(for netId: UUID) -> String {
        document.circuit.logic.nets.first(where: { $0.id == netId })?.label ?? "?"
    }

    private func componentKindLabel(_ kind: ComponentKind) -> String {
        switch kind {
        case .transistor:   return "transistor"
        case .resistor:     return "resistor"
        case .port:         return "port"
        case .vacuumSource: return "vacuum"
        case .atmVent:      return "vent"
        case .subpart:      return "subpart"
        case .screw:        return "screw"
        case .led:          return "LED"
        case .connector:    return "connector"
        }
    }

    private func componentSystemImage(_ kind: ComponentKind) -> String {
        switch kind {
        case .transistor:   return "triangle"
        case .resistor:     return "waveform.path.ecg"
        case .port:         return "arrow.right.to.line"
        case .vacuumSource: return "arrow.up.right.circle"
        case .atmVent:      return "wind"
        case .subpart:      return "rectangle.dashed"
        case .screw:        return "circle.grid.cross"
        case .led:          return "lightbulb"
        case .connector:    return "rectangle.connected.to.line.below"
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
    /// Live drag callbacks used to let the user draw a route by dragging
    /// from this pin and releasing on another. Locations are reported in
    /// the canvas's "canvas" coordinate space so the receiver can hit-test
    /// directly against the same screen positions it uses for pin rendering.
    /// Defaults to no-op so existing call sites (and tests) don't need to
    /// supply them.
    var onDragChanged: (CGPoint) -> Void = { _ in }
    var onDragEnded: (CGPoint) -> Void = { _ in }

    @State private var hovered = false
    /// On touch platforms the pin label briefly pops on tap, so the user
    /// can confirm which pin they hit (the `.help()` tooltip is hidden on
    /// iPad and `.onHover` never fires).
    @State private var touchChipUntil: Date?
    /// When the canvas is locked into pan/zoom mode, the drag-to-route
    /// gesture is masked to `.none` so the canvas's pan gesture wins.
    @Environment(\.canvasLocked) private var canvasLocked: Bool

    var body: some View {
        // The macOS dot is intentionally tiny because the cursor can land
        // it precisely; on iPad bump the dot and hit zone above the touch
        // HIG floor.
        let dot: CGFloat = InputPlatform.isTouch ? 11 : 9
        let hit: CGFloat = InputPlatform.isTouch ? 26 : 20
        return Circle()
            .fill(fillColor)
            .overlay(Circle().stroke(strokeColor, lineWidth: 1.0))
            .frame(width: dot, height: dot)
            .contentShape(Rectangle().size(width: hit, height: hit))
            .onHover { hovered = $0 }
            .onTapGesture {
                if InputPlatform.isTouch { flashTouchChip() }
                onTap()
            }
            // Drag-from-pin starts (or extends) a route and follows the
            // finger/cursor. minimumDistance keeps a slight wobble from
            // turning a tap into an accidental drag — taps under that
            // threshold still fall through to .onTapGesture. The
            // coordinate space name is set on PhysicalCanvasView's outer
            // ZStack and matches the one `mouseLocation` lives in.
            .gesture(
                DragGesture(minimumDistance: InputPlatform.isTouch ? 8 : 4,
                            coordinateSpace: .named("canvas"))
                    .onChanged { value in onDragChanged(value.location) }
                    .onEnded   { value in onDragEnded(value.location) },
                including: canvasLocked ? .none : .gesture
            )
            .overlay(alignment: .bottom) {
                if showChip {
                    pinLabelChip
                        .fixedSize()
                        .offset(y: -16)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.08), value: hovered)
            .animation(.easeOut(duration: 0.12), value: touchChipUntil)
            .help(pinKey)
    }

    private var showChip: Bool {
        if hovered { return true }
        if let until = touchChipUntil, until > .now { return true }
        return false
    }

    private var pinLabelChip: some View {
        Text(pinKey)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.primary.opacity(0.25), lineWidth: 0.5)
            )
    }

    private func flashTouchChip() {
        let deadline = Date.now.addingTimeInterval(1.4)
        touchChipUntil = deadline
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if touchChipUntil == deadline { touchChipUntil = nil }
        }
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
        // On touch the hover-grow affordance never fires, so the handle is
        // permanently a bit bigger and the hit rect grows past the touch HIG
        // floor. Macs keep the dainty default so dense routes don't look
        // like a polka-dot pattern.
        let base: CGFloat = InputPlatform.isTouch ? 12 : 10
        let active: CGFloat = InputPlatform.isTouch ? 14 : 13
        let hit: CGFloat = InputPlatform.isTouch ? 28 : 22
        let size = hovered ? active : base
        return Circle()
            .fill(Color.accentColor)
            .overlay(Circle().stroke(Color.white, lineWidth: 1.2))
            .frame(width: size, height: size)
            .contentShape(Rectangle().size(width: hit, height: hit))
            .onHover { hovered = $0 }
            .help("Drag to reshape route")
            .animation(.easeOut(duration: 0.08), value: hovered)
    }
}

// MARK: - Right-click catcher

/// SwiftUI on macOS doesn't expose secondary-button taps, so we drop a thin
/// NSView into the hierarchy that monitors `.rightMouseDown` and forwards
/// the location in SwiftUI-style (Y-down) coordinates. The view returns
/// `nil` from `hitTest` so left clicks pass through to sibling SwiftUI
/// views beneath it. On iOS / iPad there's no secondary-click concept, so
/// this is a no-op view; right-click-driven actions (removing a pin from
/// a net, deleting an interior waypoint) are unreachable on touch in v1.
struct RightClickCatcher: View {
    let onRightClick: (CGPoint) -> Void

    var body: some View {
        #if canImport(AppKit)
        RightClickCatcherRepresentable(onRightClick: onRightClick)
        #else
        Color.clear.allowsHitTesting(false)
        #endif
    }
}

#if canImport(AppKit)

private struct RightClickCatcherRepresentable: NSViewRepresentable {
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

#endif

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
        let component = document.circuit.logic.components.first(where: { $0.id == id })
        if let i = document.circuit.physical.placements.firstIndex(where: { $0.componentId == id }) {
            if component?.kind == .connector {
                PhysicalActions.snapConnector(
                    in: &document.circuit, placementIndex: i,
                    component: component!, world: world
                )
            } else {
                document.circuit.physical.placements[i].position = world
            }
        } else if component?.kind == .connector {
            // First drop on the canvas: append a Placement, then snap it
            // onto the nearest edge (which also fills in edgeAnchor /
            // rotation / layer from the role).
            document.circuit.physical.placements.append(
                Placement(componentId: id, position: world, rotation: .r0, layer: .bottom)
            )
            let newIdx = document.circuit.physical.placements.count - 1
            PhysicalActions.snapConnector(
                in: &document.circuit, placementIndex: newIdx,
                component: component!, world: world
            )
        } else {
            // Default layer follows the ratsnest: the imported part lands on
            // the layer it connects to (an outlet/inlet appears on its
            // net-mate's plate + depth, ready to route), falling back to the
            // geometric default when nothing on its nets is placed yet.
            let start: (plate: Plate, depth: Int) = component
                .map { PhysicalActions.startingLayer(for: $0, in: document.circuit) }
                ?? (plate: .top, depth: 0)
            document.circuit.physical.placements.append(
                Placement(componentId: id, position: world, rotation: .r0,
                          layer: start.plate, depth: start.depth)
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

/// Sonar-style pulse drawn at a DRC issue's focal point. Single ring that
/// scales outward and fades to zero opacity over ~1.5 s. Mounting it with a
/// fresh `id` per click restarts the animation, so re-clicking the same
/// issue still pings.
private struct IssueFocusPing: View {
    let position: Point
    let transform: CanvasTransform
    @State private var animate = false

    var body: some View {
        let screen = transform.toScreen(position)
        // Two stacked rings: the outer ring carries the pulse motion; the
        // inner ring stays put as a fixed crosshair so the user's eye can
        // still find the exact spot after the pulse has faded out.
        ZStack {
            Circle()
                .stroke(Color.orange, lineWidth: 3)
                .frame(width: 18, height: 18)
                .scaleEffect(animate ? 5 : 1)
                .opacity(animate ? 0 : 1)
            Circle()
                .stroke(Color.orange, lineWidth: 2)
                .frame(width: 12, height: 12)
                .opacity(animate ? 0.4 : 1)
        }
        .position(screen)
        .onAppear {
            withAnimation(.easeOut(duration: 1.5)) { animate = true }
        }
    }
}
