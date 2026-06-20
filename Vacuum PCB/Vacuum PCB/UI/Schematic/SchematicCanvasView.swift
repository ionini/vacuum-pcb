import SwiftUI
import UniformTypeIdentifiers

/// The main schematic editor canvas: components positioned by their schematic XY,
/// net lines drawn underneath, click-to-deselect background, rubber-band line
/// when drawing a net, marquee box-select on empty canvas, and keyboard
/// shortcuts (ESC to cancel / deselect, ⌫ to delete the selection).
struct SchematicCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    @State private var mouseLocation: CGPoint = .zero
    /// Net under the cursor, for the hover highlight. Recomputed as the cursor
    /// moves; cleared when it leaves the canvas or a net draw begins.
    @State private var hoveredNet: UUID?
    /// Show VAC/ATM rail nets as compact tap symbols (vs. wires to the source).
    /// Shared with the schematic toolbar toggle and the Simulate canvas via the
    /// same AppStorage key.
    @AppStorage("schematicShowRailTaps") private var showRailTaps = true
    /// Shared multi-component drag state. Lives here so every ComponentNodeView
    /// that participates in the same drag reads the same translation and
    /// follows in tandem.
    @State private var multiDrag: SchematicMultiDrag?
    /// Live single-component drag displacement (group drags use `multiDrag`).
    /// Render-only signal that lets the net lines track a lone symbol mid-drag.
    @State private var singleDragShift: SchematicDragShift?
    @State private var marquee: MarqueeRect?

    // MARK: - Zoom / pan
    //
    // The visible canvas is the inner ZStack rendered with `.scaleEffect`
    // (about the top-left corner) and `.offset(pan)`. Children inside the
    // scaled subtree keep operating in unscaled "schematic coord" space —
    // that's what's stored in `SchematicLayout.position`. mouseLocation,
    // marquee rects, and the rubber-band line are all unscaled.
    //
    // Cursor mapping: a window-space point P corresponds to schematic
    // coords `(P - pan) / zoom`. We use this for the right-click handler
    // (which lives outside the scaled subtree to dodge AppKit/CALayer
    // mouse-coord weirdness with NSView wrappers) and for keeping the
    // point under the cursor fixed during pinch.
    @State private var zoom: Double = 1.0
    @State private var pan: CGSize = .zero
    @State private var userAdjustedView: Bool = false
    @State private var magnifyBaseline: (zoom: Double, pan: CGSize)?
    /// Magnification value at which the pinch escaped the deadband (see
    /// `magnifyGesture`). nil while we're still ignoring small jitter.
    @State private var zoomOriginMagnification: Double?
    @State private var bgDragMode: BackgroundDragMode = .none
    @State private var panBaseline: CGSize = .zero
    @State private var lastViewSize: CGSize = CGSize(width: 800, height: 600)
    /// Monotonic tick incremented whenever a second finger touches down.
    /// `ComponentNodeView` observes this and resets its in-flight drag so
    /// the first finger's accidental component grab doesn't survive into
    /// a two-finger pan/pinch.
    @State private var dragInvalidation: Int = 0
    /// Sticky toggle that puts the canvas into pan/zoom-only mode. The
    /// `dragInvalidation` race-fix above wins most multi-touch starts,
    /// but it can't help when the user lands finger #1 well before #2 —
    /// the SwiftUI DragGesture commits to a component drag before any
    /// system-level multi-touch arbitration runs. Locking the canvas is
    /// the bulletproof fallback: single-finger drags pan instead of
    /// moving components.
    @State private var navigateMode: Bool = false
    /// Window-space mouse location, captured by an NSEvent monitor mirroring
    /// the right-click catcher. Used so ⌘= / ⌘− / pinch all zoom about the
    /// point the user is actually looking at, not the canvas centre.
    @State private var windowCursor: CGPoint = .zero

    enum BackgroundDragMode { case none, marquee, pan }

    /// Whatever drag is in flight, as a render-only shift for the wires: a
    /// group drag (`multiDrag`) or a single-symbol drag (`singleDragShift`).
    private var activeDragShift: SchematicDragShift? {
        if let m = multiDrag {
            return SchematicDragShift(participants: m.participants, translation: m.translation)
        }
        return singleDragShift
    }

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

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                // Solid backdrop sits *outside* the scaled subtree so it
                // always fills the visible canvas no matter how far the
                // user has zoomed in / out.
                Color.canvasBackground
                    .ignoresSafeArea(edges: [])

                // `scaledContent` carries the 100k×100k background tap target
                // (so deselect clicks still register at any zoom). Without
                // clamping, that intrinsic size propagates up to the outer
                // ZStack, blowing the host NSView frame way past the visible
                // canvas — which made the ScrollEventCatcher's bounds gate
                // pass for cursors over the sidebar/inspector and steal
                // their scroll events. Pinning the wrapper to `geo.size`
                // (and clipping the overflow) keeps every sibling — and the
                // ZStack itself — at the canvas's true frame.
                scaledContent
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                    .frame(width: geo.size.width, height: geo.size.height,
                           alignment: .topLeading)
                    .clipped()
                    .environment(\.schematicZoom, zoom)

                // NSEvent-monitor key catcher. Outside the scaled subtree
                // because it doesn't care about coordinates.
                KeyEventCatcher(
                    handlers: [
                        KeyCodes.delete: { deleteSelection() },
                        KeyCodes.forwardDelete: { deleteSelection() },
                        KeyCodes.r: { rotateSelection() },
                        KeyCodes.escape: {
                            netDrawState = .idle
                            selection = .none
                        },
                    ],
                    commandHandlers: [
                        KeyCodes.equals: { zoomBy(1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                        KeyCodes.minus: { zoomBy(1 / 1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                        KeyCodes.zero: { fitToView(viewSize: geo.size) },
                    ]
                )

                // Right-click a net line to remove the pin at its non-anchor
                // end from the net. Outside the scaled subtree (NSView mouse
                // coords don't play well with CALayer transforms) — we
                // convert from window space to schematic space manually.
                RightClickCatcher { pt in
                    let local = windowToSchematic(pt)
                    handleRightClick(at: local)
                }
                .allowsHitTesting(true)

                // Scroll-wheel → pan; Cmd+scroll → zoom about cursor.
                ScrollEventCatcher(
                    onPan: { dx, dy in
                        pan = CGSize(
                            width: pan.width  + Double(dx),
                            height: pan.height + Double(dy)
                        )
                        userAdjustedView = true
                    },
                    onZoom: { factor, cursor in
                        zoomBy(factor, atWindowPoint: cursor, viewSize: geo.size)
                    }
                )
                .allowsHitTesting(true)

                // iPad: two-finger drag pans, leaving one-finger drag for
                // marquee / component move / pin net-draw. Pan coords are
                // in window pts, applied directly to `pan` which is also
                // window-pt space.
                TwoFingerPanCatcher(
                    onPan: { dx, dy in
                        pan = CGSize(
                            width: pan.width  + Double(dx),
                            height: pan.height + Double(dy)
                        )
                        userAdjustedView = true
                    },
                    onMultiTouchBegan: {
                        // Second finger landed — abort any single-finger
                        // work the first finger started so pan/pinch wins.
                        multiDrag = nil
                        singleDragShift = nil
                        marquee = nil
                        bgDragMode = .none
                        dragInvalidation &+= 1
                    }
                )

                ZoomToolbar(
                    zoomPercent: zoom,
                    onZoomOut: { zoomBy(1 / 1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                    onFit: { fitToView(viewSize: geo.size) },
                    onZoomIn: { zoomBy(1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                    isLocked: navigateMode,
                    onToggleLock: {
                        navigateMode.toggle()
                        // Drop any in-flight selection/drag state so the
                        // mode flip doesn't leave the canvas mid-gesture.
                        multiDrag = nil
                        singleDragShift = nil
                        marquee = nil
                        bgDragMode = .none
                        if navigateMode { netDrawState = .idle }
                    }
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }
            .environment(\.canvasLocked, navigateMode)
            .coordinateSpace(name: "schematic-screen")
            // Drag a palette component from the inspector and drop it here to
            // place it at the cursor (grid-snapped). Mirrors the physical
            // parking lot. `info.location` arrives in this view's local space —
            // the same space `windowToSchematic` inverts.
            .onDrop(of: [.text], delegate: SchematicPaletteDropDelegate(
                document: $document,
                selection: $selection,
                toSchematic: { windowToSchematic($0) }
            ))
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(viewSize: geo.size))
            // Lock-mode pan. Child drag gestures (component move, pin
            // drag-to-route) read `\.canvasLocked` from the environment
            // and mask themselves to `.none` when locked, so this is the
            // only DragGesture left in the tree. `.subviews` mask when
            // unlocked deactivates this gesture so editing works
            // normally.
            .highPriorityGesture(
                lockPanGesture,
                including: navigateMode ? .all : .subviews
            )
            .onContinuousHover(coordinateSpace: .named("schematic-screen")) { phase in
                if case .active(let p) = phase { windowCursor = p }
            }
            .onAppear {
                lastViewSize = geo.size
                if !userAdjustedView { fitToView(viewSize: geo.size) }
            }
            .onChange(of: geo.size) { _, new in
                lastViewSize = new
                if !userAdjustedView { fitToView(viewSize: new) }
            }
        }
    }

    /// The actual canvas contents — netlines, components, rubber-band line,
    /// marquee, background tap target. Drawn at native (unscaled) schematic
    /// coordinates; the parent applies `scaleEffect` + `offset` around it.
    @ViewBuilder private var scaledContent: some View {
        ZStack(alignment: .topLeading) {
            // Background tap target inside the scaled tree: extends much
            // further than the visible viewport so even at high zoom the
            // user can still click empty space to deselect. Without this,
            // the visible inner Color would shrink to a corner under
            // scaleEffect and miss most clicks.
            Color.clear
                .frame(width: 100_000, height: 100_000)
                .contentShape(Rectangle())
                .onTapGesture {
                    if !ModifierKeys.commandHeld {
                        selection = .none
                    }
                    netDrawState = .idle
                }
                // In lock mode the canvas-root `lockPanGesture` owns
                // single-finger drags. Masking marquee to `.none` here
                // keeps it from snagging the second pinch finger that
                // happens to land on background and drawing a stray
                // selection box. SwiftUI's arbitration assigns separate
                // fingers to separate DragGestures during multi-touch,
                // so this needs to be off explicitly — not just shadowed
                // by the high-priority gesture above.
                .gesture(marqueeGesture, including: navigateMode ? .none : .gesture)
                // Touch-only: long-press a wire to drop a waypoint (the macOS
                // right-click-to-add path). Off on macOS (right-click handles
                // it) and in lock/pan mode.
                .gesture(addPointGesture,
                         including: (InputPlatform.isTouch && !navigateMode) ? .gesture : .none)

            NetLinesView(document: document.circuit, selection: selection,
                         hoveredNet: hoveredNet, railTaps: showRailTaps,
                         dragShift: activeDragShift)

            ForEach(document.circuit.logic.components.filter { $0.kind != .screw }) { component in
                let pos = document.circuit.schematic.position(for: component.id)
                    ?? Point(x: 200, y: 200)
                ComponentNodeView(
                    component: component,
                    document: $document,
                    selection: $selection,
                    netDrawState: $netDrawState,
                    multiDrag: $multiDrag,
                    liveDragShift: $singleDragShift,
                    dragInvalidation: dragInvalidation,
                    onPinDragChanged: handlePinDragChanged,
                    onPinDragEnded: handlePinDragEnded,
                    rotationQuarterTurns: document.circuit.schematic.rotation(for: component.id)
                )
                .position(x: pos.x, y: pos.y)
            }

            // Draggable wire waypoints, above the net lines.
            ForEach(Array(waypointHandles.enumerated()), id: \.offset) { _, h in
                WaypointHandleView(
                    point: h.point,
                    onChanged: { p in waypointDragChanged(pair: h.pair, index: h.index, to: p) },
                    onEnded: { p in waypointDragEnded(pair: h.pair, index: h.index, to: p) },
                    onRemove: { document.circuit.schematic.removeWaypoint(pair: h.pair, index: h.index) }
                )
            }

            if case .awaitingSecondPin(let firstPin) = netDrawState,
               let g = NetEdgeBuilder.pinGeometry(in: document.circuit)[firstPin] {
                rubberBand(from: g.point, exit: g.exit, to: mouseLocation)
            }

            marqueeOverlay
        }
        // Named coord space the pin-handle drag gesture reports in.
        // Attached inside the scaled subtree (before the parent's
        // scaleEffect/offset are applied) so gesture locations arrive in
        // unscaled schematic units — the same coord system pin/component
        // positions live in. Putting this on the outer modifier chain
        // would yield post-scaled screen pts instead and the hit test
        // would drift with zoom/pan.
        .coordinateSpace(name: "schematic-canvas")
        .onContinuousHover { phase in
            // Local-coord hover lives inside the scaled subtree so its
            // value is already in schematic units — usable directly for
            // rubber-band rendering and marquee math.
            switch phase {
            case .active(let pos):
                mouseLocation = pos
                updateHoveredNet(at: pos)
            case .ended:
                if hoveredNet != nil { hoveredNet = nil }
            }
        }
    }

    // MARK: - Zoom math

    /// Recompute zoom + pan to fit every placed component into the visible
    /// viewport with a comfortable margin. Falls back to identity when the
    /// schematic is empty (so a brand-new doc renders at 1:1, ready to
    /// receive its first component at the top-left).
    private func fitToView(viewSize: CGSize) {
        guard viewSize.width > 50, viewSize.height > 50 else { return }
        let positions = document.circuit.logic.components
            .filter { $0.kind != .screw }
            .compactMap { document.circuit.schematic.position(for: $0.id) }
        guard !positions.isEmpty else {
            zoom = 1.0
            pan = .zero
            userAdjustedView = false
            return
        }
        // Bounding rect padded by a generous component-size margin so the
        // outermost glyphs (which extend by ±45 schematic units around
        // their centre) aren't clipped at the viewport edge.
        let pad: Double = 70
        let minX = positions.map(\.x).min()! - pad
        let maxX = positions.map(\.x).max()! + pad
        let minY = positions.map(\.y).min()! - pad
        let maxY = positions.map(\.y).max()! + pad
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let margin: Double = 24
        let availW = max(1, Double(viewSize.width)  - 2 * margin)
        let availH = max(1, Double(viewSize.height) - 2 * margin)
        let scale = min(availW / w, availH / h, 2.0)        // clamp so empty docs don't blow up
        let usedW = w * scale, usedH = h * scale
        zoom = scale
        pan = CGSize(
            width: (Double(viewSize.width)  - usedW) / 2 - minX * scale,
            height: (Double(viewSize.height) - usedH) / 2 - minY * scale
        )
        userAdjustedView = false
    }

    /// Zoom about a screen-space anchor point so the schematic coord
    /// under the anchor stays put across the change. Used by the keyboard
    /// shortcuts and the zoom-toolbar buttons.
    private func zoomBy(_ factor: Double, atWindowPoint anchor: CGPoint, viewSize: CGSize) {
        let anchorPoint = anchor == .zero
            ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            : anchor
        let minZoom = 0.1, maxZoom = 10.0
        let newZoom = max(minZoom, min(maxZoom, zoom * factor))
        let actualFactor = newZoom / zoom
        guard abs(actualFactor - 1) > 0.0001 else { return }
        pan = CGSize(
            width: Double(anchorPoint.x) - (Double(anchorPoint.x) - pan.width)  * actualFactor,
            height: Double(anchorPoint.y) - (Double(anchorPoint.y) - pan.height) * actualFactor
        )
        zoom = newZoom
        userAdjustedView = true
    }

    /// Active only when `navigateMode` is on. A single-finger drag
    /// anywhere on the canvas pans the viewport, beating any child drag
    /// gesture (component move, pin drag-to-route) thanks to its
    /// `.highPriorityGesture` attachment on the canvas root. The outer
    /// modifier chain is outside the scaleEffect/offset subtree, so
    /// `value.translation` arrives in window points already — no zoom
    /// rescale (unlike `marqueeGesture`, which lives inside the scaled
    /// subtree and divides accordingly).
    private var lockPanGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode != .pan {
                    bgDragMode = .pan
                    panBaseline = pan
                }
                pan = CGSize(
                    width: panBaseline.width  + value.translation.width,
                    height: panBaseline.height + value.translation.height
                )
                userAdjustedView = true
            }
            .onEnded { _ in
                bgDragMode = .none
            }
    }

    /// See the matching comment on `PhysicalCanvasView.magnifyGesture`
    /// for the deadband rationale.
    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseline == nil {
                    magnifyBaseline = (zoom, pan)
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
                let anchor = windowCursor == .zero
                    ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                    : windowCursor
                let factor = max(0.05, value.magnification / origin)
                let newZoom = max(0.1, min(10.0, base.zoom * factor))
                pan = CGSize(
                    width: Double(anchor.x) - (Double(anchor.x) - base.pan.width)  * (newZoom / base.zoom),
                    height: Double(anchor.y) - (Double(anchor.y) - base.pan.height) * (newZoom / base.zoom)
                )
                zoom = newZoom
                userAdjustedView = true
            }
            .onEnded { _ in
                magnifyBaseline = nil
                zoomOriginMagnification = nil
            }
    }

    /// Converts a window-space point (received from the right-click catcher
    /// or other AppKit hooks) into the unscaled schematic coord space the
    /// rest of the canvas operates in.
    private func windowToSchematic(_ p: CGPoint) -> CGPoint {
        let s = max(0.01, zoom)
        return CGPoint(x: (Double(p.x) - pan.width) / s, y: (Double(p.y) - pan.height) / s)
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

    /// Touch equivalent of macOS right-click-to-add-waypoint: long-press a wire
    /// to drop a point there. `LongPressGesture` alone doesn't report where the
    /// press landed, so we sequence a zero-distance drag purely to recover the
    /// location; `.local` is the scaled-content space, i.e. schematic coords —
    /// exactly what `addWaypoint` expects. Removal on touch is the waypoint
    /// dot's context menu (`WaypointHandleView`).
    private var addPointGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.4, maximumDistance: 10)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
            .onEnded { value in
                if case .second(true, let drag?) = value {
                    addWaypoint(at: drag.location)
                }
            }
    }

    private var marqueeGesture: some Gesture {
        // Plain drag = marquee (in schematic coords). Option-held drag =
        // pan the viewport (in window coords). Mode is latched at first
        // tick so the user can release Option mid-gesture without
        // flipping. Lock-mode pan goes through `lockPanGesture` on the
        // canvas root instead — this whole gesture is masked off when
        // locked.
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode == .none {
                    if ModifierKeys.optionHeld {
                        bgDragMode = .pan
                        panBaseline = pan
                    } else {
                        bgDragMode = .marquee
                    }
                }
                switch bgDragMode {
                case .pan:
                    // Pan in window-space pixels. value.translation is in
                    // the gesture's local coords (schematic units) — scale
                    // up by zoom so the cursor follows the drag 1:1.
                    pan = CGSize(
                        width: panBaseline.width  + value.translation.width  * zoom,
                        height: panBaseline.height + value.translation.height * zoom
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
                guard rect.width > 2 || rect.height > 2 else { return }
                applyMarquee(rect: rect, additive: ModifierKeys.commandHeld)
            }
    }

    /// Includes a component if any of its pins falls inside the marquee — pin
    /// positions are what the user is visually aiming at, and they cover the
    /// component's footprint sufficiently for marquee selection.
    private func applyMarquee(rect: CGRect, additive: Bool) {
        var hits: Set<UUID> = []
        for component in document.circuit.logic.components {
            guard let center = document.circuit.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics
                .metrics(for: component, snapshots: document.circuit.librarySnapshots)
                .rotated(by: document.circuit.schematic.rotation(for: component.id))
            // Use the component's bounding rect (centered on its schematic
            // position) as the hit area. Marquee that touches any pixel of
            // the symbol counts as hit.
            let halfW = metrics.size.width / 2
            let halfH = metrics.size.height / 2
            let bodyRect = CGRect(
                x: center.x - halfW, y: center.y - halfH,
                width: metrics.size.width, height: metrics.size.height
            )
            if rect.intersects(bodyRect) {
                hits.insert(component.id)
            }
        }
        var next = additive ? selection : SchematicSelection.none
        next.net = nil
        next.components.formUnion(hits)
        selection = next
    }

    // MARK: - Rubber band

    private func rubberBand(from a: CGPoint, exit: ExitDir, to b: CGPoint) -> some View {
        // Free end at the cursor (nil exit) so the line stubs out of the
        // anchored pin and meets the cursor with one orthogonal turn.
        WireRouter.roundedPath(WireRouter.route(from: a, exit, to: b, nil), radius: 9)
            .stroke(
                Color.accentColor.opacity(0.8),
                style: StrokeStyle(lineWidth: 1.6, lineJoin: .round, dash: [4, 3])
            )
            .allowsHitTesting(false)
    }

    // MARK: - Pin drag (drag-to-route)

    /// Live drag update from a pin handle: start the net draw on the first
    /// tick (so the rubber-band locks to this pin) and keep `mouseLocation`
    /// in step with the finger/cursor so the rendered line follows it.
    private func handlePinDragChanged(_ ref: PinRef, at canvasPt: CGPoint) {
        if case .idle = netDrawState {
            netDrawState = .awaitingSecondPin(firstPin: ref)
        }
        mouseLocation = canvasPt
    }

    /// Release on another pin commits the net; release in empty space
    /// leaves the awaiting-second-pin state intact so a follow-up tap can
    /// finish the connection. Mirrors the physical canvas's drag-to-route.
    private func handlePinDragEnded(_ ref: PinRef, at canvasPt: CGPoint) {
        guard case .awaitingSecondPin(let firstPin) = netDrawState else { return }
        guard let target = pinHit(at: canvasPt) else {
            // No drop pin — leave the net draw active so the user can
            // finish with a tap.
            return
        }
        defer { netDrawState = .idle }
        guard target != firstPin else { return }
        document.circuit.connectPins(firstPin, target)
        _ = ref  // touched so the auto-capture is explicit in the diff
    }

    /// Nearest visible pin under a schematic-space point, with a slop
    /// radius matched to the pin handle's hit zone. Iterates every
    /// component's pins; the schematic graph is small enough that this
    /// linear scan never shows up in practice.
    private func pinHit(at schematicPt: CGPoint) -> PinRef? {
        let radius: Double = InputPlatform.isTouch ? 18 : 14
        let radiusSq = radius * radius
        var best: (ref: PinRef, distSq: Double)?
        // `pinGeometry` already resolves rotated pin positions and skips
        // screws (they carry no pins), so the hit-test follows the symbols.
        for (ref, geo) in NetEdgeBuilder.pinGeometry(in: document.circuit) {
            let dx = Double(schematicPt.x) - Double(geo.point.x)
            let dy = Double(schematicPt.y) - Double(geo.point.y)
            let d2 = dx * dx + dy * dy
            if d2 <= radiusSq, d2 < (best?.distSq ?? .greatestFiniteMagnitude) {
                best = (ref, d2)
            }
        }
        return best?.ref
    }

    // MARK: - Hover highlight

    /// Highlights the net nearest the cursor (within a small slop) by storing
    /// its id; `NetLinesView` strokes it brighter. Skipped while drawing a net
    /// — the rubber band owns the cursor then. Builds the pin-geometry map once
    /// and shares it across nets so the frequent hover ticks stay cheap.
    private func updateHoveredNet(at pt: CGPoint) {
        guard case .idle = netDrawState else {
            if hoveredNet != nil { hoveredNet = nil }
            return
        }
        let threshold = 10.0
        var best: (netId: UUID, distance: Double)?
        for net in SchematicWireGeometry.render(in: document.circuit, railTaps: showRailTaps) {
            var d = Double.greatestFiniteMagnitude
            for edge in net.edges {
                d = min(d, Double(WireRouter.distance(from: pt, to: edge.points)))
            }
            for tap in net.taps {
                d = min(d, hypot(Double(pt.x - tap.point.x), Double(pt.y - tap.point.y)))
            }
            if d <= threshold, d < (best?.distance ?? .greatestFiniteMagnitude) {
                best = (net.netId, d)
            }
        }
        let next = best?.netId
        if next != hoveredNet { hoveredNet = next }
    }

    // MARK: - Right-click on a net line

    private func handleRightClick(at pt: CGPoint) {
        // Contextual: remove a waypoint you clicked; else disconnect a pin you
        // clicked; else drop a new waypoint on the wire under the cursor.
        if let hit = waypointHit(at: pt) {
            document.circuit.schematic.removeWaypoint(pair: hit.pair, index: hit.index)
            return
        }
        if let pin = pinHit(at: pt), let netId = netContaining(pin) {
            removePin(pin, fromNet: netId)
            return
        }
        addWaypoint(at: pt)
    }

    /// Nearest existing waypoint within a small slop, for right-click removal.
    private func waypointHit(at pt: CGPoint) -> (pair: PinPair, index: Int)? {
        let slop: CGFloat = 10
        var best: (pair: PinPair, index: Int, d: CGFloat)?
        for entry in document.circuit.schematic.wireWaypoints ?? [] {
            for (i, p) in entry.points.enumerated() {
                let d = hypot(CGFloat(p.x) - pt.x, CGFloat(p.y) - pt.y)
                if d <= slop, d < (best?.d ?? .greatestFiniteMagnitude) {
                    best = (entry.pair, i, d)
                }
            }
        }
        return best.map { ($0.pair, $0.index) }
    }

    private func netContaining(_ pin: PinRef) -> UUID? {
        document.circuit.logic.nets.first(where: { $0.pins.contains(pin) })?.id
    }

    /// Drops a waypoint on the wire nearest the cursor — snapped onto the wire
    /// and inserted in path order among any existing waypoints, so the wire
    /// doesn't jump when it appears.
    private func addWaypoint(at pt: CGPoint) {
        let slop: CGFloat = 8
        var best: (a: PinRef, b: PinRef, points: [CGPoint], d: CGFloat)?
        for net in SchematicWireGeometry.render(in: document.circuit, railTaps: showRailTaps) {
            for e in net.edges {
                let d = WireRouter.distance(from: pt, to: e.points)
                if d <= slop, d < (best?.d ?? .greatestFiniteMagnitude) {
                    best = (e.a, e.b, e.points, d)
                }
            }
        }
        guard let hit = best else { return }
        let proj = WireRouter.projection(of: pt, onto: hit.points)
        var entries: [(p: CGPoint, t: CGFloat)] = document.circuit.schematic
            .waypoints(hit.a, hit.b)
            .map { wp in
                let cp = CGPoint(x: wp.x, y: wp.y)
                return (cp, WireRouter.projection(of: cp, onto: hit.points).arclength)
            }
        entries.append((proj.point, proj.arclength))
        entries.sort { $0.t < $1.t }
        document.circuit.schematic.setWaypoints(
            entries.map { Point(x: $0.p.x, y: $0.p.y) }, a: hit.a, b: hit.b
        )
    }

    private func waypointDragChanged(pair: PinPair, index: Int, to p: CGPoint) {
        document.circuit.schematic.moveWaypoint(pair: pair, index: index,
                                                to: Point(x: p.x, y: p.y))
    }

    private func waypointDragEnded(pair: PinPair, index: Int, to p: CGPoint) {
        document.circuit.schematic.moveWaypoint(pair: pair, index: index,
                                                to: SchematicLayout.snapToGrid(Point(x: p.x, y: p.y)))
    }

    /// Flattened list of every wire waypoint, for placing its drag handle.
    private var waypointHandles: [(pair: PinPair, index: Int, point: CGPoint)] {
        (document.circuit.schematic.wireWaypoints ?? []).flatMap { entry in
            entry.points.enumerated().map {
                (entry.pair, $0.offset, CGPoint(x: $0.element.x, y: $0.element.y))
            }
        }
    }

    private func removePin(_ pin: PinRef, fromNet netId: UUID) {
        guard let i = document.circuit.logic.nets.firstIndex(where: { $0.id == netId })
        else { return }
        document.circuit.logic.nets[i].pins.removeAll { $0 == pin }
        if document.circuit.logic.nets[i].pins.count < 2 {
            let killed = document.circuit.logic.nets[i].id
            document.circuit.logic.nets.remove(at: i)
            document.circuit.physical.routes.removeAll { $0.netId == killed }
            if selection.contains(net: killed) { selection.net = nil }
        }
    }

    // MARK: - Deletion

    private func deleteSelection() {
        SchematicActions.delete(document: &document, selection: &selection)
    }

    /// Rotate every selected component 90° clockwise (R key). Mirrors
    /// `deleteSelection` — the inspector's "Rotate 90°" button drives the
    /// same `SchematicActions.rotate` path.
    private func rotateSelection() {
        SchematicActions.rotate(document: &document, selection: selection)
    }
}

// MARK: - Drop delegate for palette drag-to-place

/// Accepts a component dragged from the inspector palette and creates it at the
/// drop point (grid-snapped). Mirrors `ParkingDropDelegate` on the physical
/// canvas, but the schematic palette ships a kind, not an existing id, so this
/// makes a new component rather than moving one.
struct SchematicPaletteDropDelegate: DropDelegate {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    /// Window/local-space point → schematic coordinates (the canvas's
    /// `windowToSchematic`).
    let toSchematic: (CGPoint) -> CGPoint

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.text])
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        let dropPoint = info.location
        let toSchematic = self.toSchematic
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            guard let raw = Self.string(from: item),
                  case let .primitive(kind, dir)? = SchematicPaletteDrag(dragString: raw)
            else { return }
            DispatchQueue.main.async {
                let p = toSchematic(dropPoint)
                let at = SchematicLayout.snapToGrid(Point(x: p.x, y: p.y))
                let component = SchematicActions.makeComponent(
                    kind: kind, portDirection: dir, in: document.circuit)
                document.circuit.logic.components.append(component)
                document.circuit.schematic.setPosition(at, for: component.id)
                selection = .component(component.id)
            }
        }
        return true
    }

    private static func string(from item: NSSecureCoding?) -> String? {
        if let d = item as? Data { return String(data: d, encoding: .utf8) }
        if let s = item as? NSString { return s as String }
        return item as? String
    }
}
