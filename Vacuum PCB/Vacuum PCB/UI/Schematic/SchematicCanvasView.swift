import SwiftUI

/// The main schematic editor canvas: components positioned by their schematic XY,
/// net lines drawn underneath, click-to-deselect background, rubber-band line
/// when drawing a net, marquee box-select on empty canvas, and keyboard
/// shortcuts (ESC to cancel / deselect, ⌫ to delete the selection).
struct SchematicCanvasView: View {
    @Binding var document: VPCBDocument
    @Binding var selection: SchematicSelection
    @Binding var netDrawState: NetDrawState

    @State private var mouseLocation: CGPoint = .zero
    /// Shared multi-component drag state. Lives here so every ComponentNodeView
    /// that participates in the same drag reads the same translation and
    /// follows in tandem.
    @State private var multiDrag: SchematicMultiDrag?
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
    @State private var bgDragMode: BackgroundDragMode = .none
    @State private var panBaseline: CGSize = .zero
    @State private var lastViewSize: CGSize = CGSize(width: 800, height: 600)
    /// Window-space mouse location, captured by an NSEvent monitor mirroring
    /// the right-click catcher. Used so ⌘= / ⌘− / pinch all zoom about the
    /// point the user is actually looking at, not the canvas centre.
    @State private var windowCursor: CGPoint = .zero

    enum BackgroundDragMode { case none, marquee, pan }

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
                Color(NSColor.controlBackgroundColor)
                    .ignoresSafeArea(edges: [])

                scaledContent
                    .scaleEffect(zoom, anchor: .topLeading)
                    .offset(pan)
                    .environment(\.schematicZoom, zoom)

                // NSEvent-monitor key catcher. Outside the scaled subtree
                // because it doesn't care about coordinates.
                KeyEventCatcher(
                    handlers: [
                        KeyCodes.delete: { deleteSelection() },
                        KeyCodes.forwardDelete: { deleteSelection() },
                        KeyCodes.escape: {
                            netDrawState = .idle
                            selection = .none
                        },
                    ],
                    commandHandlers: [
                        KeyCodes.equals: { zoomBy(1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                        KeyCodes.minus:  { zoomBy(1 / 1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                        KeyCodes.zero:   { fitToView(viewSize: geo.size) },
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
                            width:  pan.width  + Double(dx),
                            height: pan.height + Double(dy)
                        )
                        userAdjustedView = true
                    },
                    onZoom: { factor, cursor in
                        zoomBy(factor, atWindowPoint: cursor, viewSize: geo.size)
                    }
                )
                .allowsHitTesting(true)

                ZoomToolbar(
                    zoomPercent: zoom,
                    onZoomOut: { zoomBy(1 / 1.25, atWindowPoint: windowCursor, viewSize: geo.size) },
                    onFit:     { fitToView(viewSize: geo.size) },
                    onZoomIn:  { zoomBy(1.25, atWindowPoint: windowCursor, viewSize: geo.size) }
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }
            .coordinateSpace(name: "schematic-screen")
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(viewSize: geo.size))
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
                    if !NSEvent.modifierFlags.contains(.command) {
                        selection = .none
                    }
                    netDrawState = .idle
                }
                .gesture(marqueeGesture)

            NetLinesView(document: document.circuit, selection: selection)

            ForEach(document.circuit.logic.components.filter { $0.kind != .screw }) { component in
                let pos = document.circuit.schematic.position(for: component.id)
                    ?? Point(x: 200, y: 200)
                ComponentNodeView(
                    component: component,
                    document: $document,
                    selection: $selection,
                    netDrawState: $netDrawState,
                    multiDrag: $multiDrag
                )
                .position(x: pos.x, y: pos.y)
            }

            if case .awaitingSecondPin(let firstPin) = netDrawState,
               let start = pinScreenPosition(firstPin) {
                rubberBand(from: start, to: mouseLocation)
            }

            marqueeOverlay
        }
        .onContinuousHover { phase in
            // Local-coord hover lives inside the scaled subtree so its
            // value is already in schematic units — usable directly for
            // rubber-band rendering and marquee math.
            switch phase {
            case .active(let pos): mouseLocation = pos
            case .ended: break
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
            width:  (Double(viewSize.width)  - usedW) / 2 - minX * scale,
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
            width:  Double(anchorPoint.x) - (Double(anchorPoint.x) - pan.width)  * actualFactor,
            height: Double(anchorPoint.y) - (Double(anchorPoint.y) - pan.height) * actualFactor
        )
        zoom = newZoom
        userAdjustedView = true
    }

    private func magnifyGesture(viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseline == nil { magnifyBaseline = (zoom, pan) }
                guard let base = magnifyBaseline else { return }
                let anchor = windowCursor == .zero
                    ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
                    : windowCursor
                let factor = max(0.05, value.magnification)
                let newZoom = max(0.1, min(10.0, base.zoom * factor))
                pan = CGSize(
                    width:  Double(anchor.x) - (Double(anchor.x) - base.pan.width)  * (newZoom / base.zoom),
                    height: Double(anchor.y) - (Double(anchor.y) - base.pan.height) * (newZoom / base.zoom)
                )
                zoom = newZoom
                userAdjustedView = true
            }
            .onEnded { _ in magnifyBaseline = nil }
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

    private var marqueeGesture: some Gesture {
        // Plain drag = marquee (in schematic coords). Option-held drag =
        // pan the viewport (in window coords). Mode is latched at first
        // tick so the user can release Option mid-gesture without flipping.
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if bgDragMode == .none {
                    if NSEvent.modifierFlags.contains(.option) {
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
                        width:  panBaseline.width  + value.translation.width  * zoom,
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
                applyMarquee(rect: rect, additive: NSEvent.modifierFlags.contains(.command))
            }
    }

    /// Includes a component if any of its pins falls inside the marquee — pin
    /// positions are what the user is visually aiming at, and they cover the
    /// component's footprint sufficiently for marquee selection.
    private func applyMarquee(rect: CGRect, additive: Bool) {
        var hits: Set<UUID> = []
        for component in document.circuit.logic.components {
            guard let center = document.circuit.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics.metrics(for: component)
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

    private func rubberBand(from a: CGPoint, to b: CGPoint) -> some View {
        Path { p in
            p.move(to: a)
            p.addLine(to: b)
        }
        .stroke(Color.accentColor.opacity(0.8), style: StrokeStyle(lineWidth: 1.6, dash: [4, 3]))
        .allowsHitTesting(false)
    }

    private func pinScreenPosition(_ ref: PinRef) -> CGPoint? {
        guard let comp = document.circuit.logic.components.first(where: { $0.id == ref.componentId }),
              let center = document.circuit.schematic.position(for: ref.componentId)
        else { return nil }
        let metrics = ComponentSymbolMetrics.metrics(for: comp)
        let off = metrics.pinOffset(ref.pinKey)
        return CGPoint(x: center.x + off.x, y: center.y + off.y)
    }

    // MARK: - Right-click on a net line

    private func handleRightClick(at pt: CGPoint) {
        let threshold: Double = 8
        var best: (netId: UUID, pinToRemove: PinRef, distance: Double)?
        for net in document.circuit.logic.nets {
            for edge in NetEdgeBuilder.edges(for: net, in: document.circuit) {
                let d = distanceFromPoint(pt, toSegmentFrom: edge.a.point, to: edge.b.point)
                guard d <= threshold else { continue }
                if d < (best?.distance ?? .greatestFiniteMagnitude) {
                    let aDist = hypot(Double(pt.x - edge.a.point.x), Double(pt.y - edge.a.point.y))
                    let bDist = hypot(Double(pt.x - edge.b.point.x), Double(pt.y - edge.b.point.y))
                    let pin = aDist < bDist ? edge.a.pin : edge.b.pin
                    best = (net.id, pin, d)
                }
            }
        }
        guard let hit = best else { return }
        removePin(hit.pinToRemove, fromNet: hit.netId)
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

    private func distanceFromPoint(_ p: CGPoint, toSegmentFrom a: CGPoint, to b: CGPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return hypot(Double(p.x - a.x), Double(p.y - a.y)) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return hypot(Double(p.x - (a.x + CGFloat(t) * dx)),
                     Double(p.y - (a.y + CGFloat(t) * dy)))
    }

    // MARK: - Deletion

    private func deleteSelection() {
        for id in selection.components {
            deleteComponent(id)
        }
        if let netId = selection.net {
            deleteNet(netId)
        }
        selection = .none
    }

    private func deleteComponent(_ id: UUID) {
        document.circuit.logic.components.removeAll { $0.id == id }
        document.circuit.schematic.remove(componentId: id)
        for i in document.circuit.logic.nets.indices {
            document.circuit.logic.nets[i].pins.removeAll { $0.componentId == id }
        }
        let dead = document.circuit.logic.nets.filter { $0.pins.count < 2 }.map(\.id)
        document.circuit.logic.nets.removeAll { dead.contains($0.id) }
        document.circuit.physical.routes.removeAll { dead.contains($0.netId) }
        document.circuit.physical.placements.removeAll { $0.componentId == id }
    }

    private func deleteNet(_ id: UUID) {
        document.circuit.logic.nets.removeAll { $0.id == id }
        document.circuit.physical.routes.removeAll { $0.netId == id }
    }
}
