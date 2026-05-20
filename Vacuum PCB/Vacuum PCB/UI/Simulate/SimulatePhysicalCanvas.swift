import SwiftUI

/// Read-only physical-style heatmap. Draws the board outline, every route,
/// and every component body — but instead of layer-coloured routes the
/// strokes are pressure-tinted, so the user can spatially trace which
/// channels are pulling vacuum and which are sitting at atmosphere.
///
/// Routes inherit their net's pressure (one node per net in v1); component
/// bodies pick a representative pin pressure (gate for transistors, "p" for
/// rail / port / LED, mean of the two ends for resistors).
///
/// Pan / zoom mirrors the editor's `PhysicalCanvasView`: the user-driven
/// `CanvasTransform` mutates `ptsPerMm` directly so the Canvas redraws
/// crisply at every zoom level (no scaleEffect rasterization).
struct SimulatePhysicalCanvas: View {
    /// Parent document. Used for board outline and the initial fit. Net
    /// pressures and component bodies come from the simulation state's
    /// cached subpart-flattened snapshot so library internals render.
    let document: CircuitDocument
    @Bindable var state: SimulationState
    /// Which layers the user has chosen to display. Matches the editor's
    /// per-layer pills so the user can isolate e.g. just B0 to trace one
    /// channel layer's pressure flow without overlapping strokes from other
    /// depths/plates.
    let visible: LayerVisibility

    /// Subpart-flattened doc the simulator solves on. The Physical canvas
    /// renders from this so a subpart's library-internal transistors,
    /// resistors and routes appear at their world-space positions.
    private var flat: CircuitDocument { state.flattenedDoc }

    @State private var transform: CanvasTransform = .default
    @State private var userAdjusted: Bool = false
    @State private var magnifyBaseline: (ptsPerMm: Double, offset: CGSize)?
    @State private var panBaseline: CGSize = .zero
    @State private var windowCursor: CGPoint = .zero
    @State private var bgDragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.canvasBackground
                    .ignoresSafeArea(edges: [])

                Canvas { ctx, _ in
                    drawBoard(in: &ctx)
                    drawRoutes(in: &ctx)
                    drawComponents(in: &ctx)
                }
                .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .gesture(panGesture)

                KeyEventCatcher(
                    handlers: [:],
                    commandHandlers: [
                        KeyCodes.equals: { zoomBy(1.25, anchor: anchorPoint(in: geo.size)) },
                        KeyCodes.minus:  { zoomBy(1 / 1.25, anchor: anchorPoint(in: geo.size)) },
                        KeyCodes.zero:   { fit(in: geo.size) },
                    ]
                )

                ScrollEventCatcher(
                    onPan: { dx, dy in
                        transform.offset = CGSize(
                            width: transform.offset.width + dx,
                            height: transform.offset.height + dy
                        )
                        userAdjusted = true
                    },
                    onZoom: { factor, cursor in
                        zoomBy(factor, anchor: cursor)
                    }
                )
                .allowsHitTesting(true)

                ZoomToolbar(
                    zoomPercent: transform.ptsPerMm / CanvasTransform.default.ptsPerMm,
                    onZoomOut: { zoomBy(1 / 1.25, anchor: anchorPoint(in: geo.size)) },
                    onFit:     { fit(in: geo.size) },
                    onZoomIn:  { zoomBy(1.25, anchor: anchorPoint(in: geo.size)) }
                )
                .padding(8)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .allowsHitTesting(true)
            }
            .coordinateSpace(name: "simulate-physical")
            .clipped()
            .contentShape(Rectangle())
            .gesture(magnifyGesture(in: geo.size))
            .onContinuousHover(coordinateSpace: .named("simulate-physical")) { phase in
                if case .active(let p) = phase { windowCursor = p }
            }
            .onAppear {
                if !userAdjusted { fit(in: geo.size) }
            }
            .onChange(of: geo.size) { _, new in
                if !userAdjusted { fit(in: new) }
            }
        }
    }

    // MARK: - Drawing

    private func drawBoard(in ctx: inout GraphicsContext) {
        let outline = document.physical.boardOutline
        let topLeft = transform.toScreen(outline.origin)
        let size = transform.toScreenSize(outline.size)
        let rect = CGRect(x: topLeft.x, y: topLeft.y, width: size.width, height: size.height)
        ctx.fill(Path(rect), with: .color(Color.gray.opacity(0.15)))
        ctx.stroke(Path(rect), with: .color(Color.gray), lineWidth: 1.2)
    }

    private func drawRoutes(in ctx: inout GraphicsContext) {
        let stroke = max(2.0, document.manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
        for route in flat.physical.routes {
            let pressure = state.pressure(net: route.netId)
            let color = PressureColor.strokeColor(for: pressure)
            for segment in route.segments {
                guard visible.contains(segment.layer) else { continue }
                let pts = segment.waypoints.map { transform.toScreen($0.position) }
                guard pts.count >= 2 else { continue }
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }
                ctx.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: stroke, lineCap: .round, lineJoin: .round)
                )
            }
        }
    }

    private func drawComponents(in ctx: inout GraphicsContext) {
        let netByPin = PneumaticNetwork.pinToNetMap(flat)
        for placement in flat.physical.placements {
            guard let component = flat.logic.components
                    .first(where: { $0.id == placement.componentId })
            else { continue }
            // Screws have no layer story (they bridge both plates), so they
            // stay visible regardless of the filter — same convention as the
            // editing canvas.
            if component.kind != .screw,
               !visible.contains(Layer(plate: placement.layer, depth: placement.depth)) {
                continue
            }
            let p = representativePressure(for: component, netByPin: netByPin)
            let center = transform.toScreen(placement.position)
            drawBody(in: &ctx, component: component, placement: placement,
                     center: center, pressure: p)
        }
    }

    /// Pressure that defines this component's tint. Mirrors the schematic
    /// canvas so the two views stay visually coherent.
    private func representativePressure(for component: Component,
                                        netByPin: [PinRef: UUID]) -> Double {
        func pressure(of pinKey: String) -> Double {
            let ref = PinRef(componentId: component.id, pinKey: pinKey)
            guard let netId = netByPin[ref] else { return 1.0 }
            return state.pressure(net: netId)
        }
        switch component.kind {
        case .transistor:    return pressure(of: "gate")
        case .resistor:      return (pressure(of: "1") + pressure(of: "2")) / 2
        case .vacuumSource:  return 0
        case .atmVent:       return 1
        case .port, .led:    return pressure(of: "p")
        case .subpart, .screw: return 1
        }
    }

    /// Per-kind body glyph in pressure-tinted strokes. Geometry follows the
    /// editing canvas at a level of detail that still reads at small zoom.
    private func drawBody(in ctx: inout GraphicsContext,
                          component: Component, placement: Placement,
                          center: CGPoint, pressure: Double) {
        let m = document.manufacturing
        let stroke = PressureColor.strokeColor(for: pressure)
        let fill = PressureColor.color(for: pressure).opacity(0.5)
        switch component.kind {
        case .transistor:
            let r = m.dimpleDiameter / 2 * transform.ptsPerMm
            let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            ctx.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 1.4)
            // Open/closed indicator: a small filled inner dot whose size
            // tracks the open-fraction so the user can see modulation.
            let openness = state.transistorOpenness[component.id] ?? 0
            let inner = r * (0.15 + 0.6 * openness)
            let innerRect = CGRect(x: center.x - inner, y: center.y - inner,
                                   width: 2 * inner, height: 2 * inner)
            ctx.fill(Path(ellipseIn: innerRect), with: .color(stroke.opacity(0.9)))
        case .resistor:
            let halfLen = ManufacturingConstants.resistorFootprintLength / 2
            let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
            let pts = ResistorGeometry.path(
                transitions: ResistorGeometry.transitions(for: component.resistorSize ?? .medium),
                halfLen: halfLen, halfWid: halfWid
            )
            let mapped = pts.map { p -> CGPoint in
                let local = rotated(p, angle: placement.rotation.radians)
                return CGPoint(
                    x: center.x + local.x * transform.ptsPerMm,
                    y: center.y + local.y * transform.ptsPerMm
                )
            }
            guard let first = mapped.first else { return }
            var path = Path()
            path.move(to: first)
            for p in mapped.dropFirst() { path.addLine(to: p) }
            ctx.stroke(
                path, with: .color(stroke),
                style: StrokeStyle(
                    lineWidth: max(1.5, m.resistorChannelDiameter * transform.ptsPerMm * 0.9),
                    lineCap: .round, lineJoin: .round
                )
            )
        case .port, .vacuumSource, .atmVent:
            let r = m.portBoreDiameter * 0.7 * transform.ptsPerMm
            let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            ctx.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 1.4)
            let dir = Double(placement.rotation.radians)
            let outer = CGPoint(
                x: center.x + cos(dir) * r * 1.7,
                y: center.y + sin(dir) * r * 1.7
            )
            var line = Path()
            line.move(to: center)
            line.addLine(to: outer)
            ctx.stroke(line, with: .color(stroke), lineWidth: 1.2)
        case .led:
            let r = m.ledDimpleDiameter / 2 * transform.ptsPerMm
            let rect = CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
            ctx.fill(Path(ellipseIn: rect), with: .color(fill))
            ctx.stroke(Path(ellipseIn: rect), with: .color(stroke), lineWidth: 1.4)
            let lit = state.params.gateOpenness(forPressure: pressure)
            if lit > 0 {
                ctx.fill(Path(ellipseIn: rect.insetBy(dx: r * 0.25, dy: r * 0.25)),
                         with: .color(Color.yellow.opacity(0.4 + 0.5 * lit)))
            }
        case .subpart, .screw:
            break
        }

        // Label centred just below the body.
        ctx.draw(
            Text(component.label).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary),
            at: CGPoint(x: center.x, y: center.y + labelDrop(for: component))
        )
    }

    private func labelDrop(for component: Component) -> CGFloat {
        let m = document.manufacturing
        let half: Double
        switch component.kind {
        case .transistor:    half = m.dimpleDiameter / 2
        case .resistor:      half = ManufacturingConstants.resistorFootprintWidth / 2
        case .led:           half = m.ledDimpleDiameter / 2
        default:             half = max(2.0, m.portBoreDiameter * 0.8)
        }
        return CGFloat(half * transform.ptsPerMm) + 10
    }

    private func rotated(_ p: Point, angle: Double) -> Point {
        let c = cos(angle), s = sin(angle)
        return Point(x: p.x * c - p.y * s, y: p.x * s + p.y * c)
    }

    // MARK: - Pan / zoom

    private func anchorPoint(in viewSize: CGSize) -> CGPoint {
        windowCursor == .zero
            ? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
            : windowCursor
    }

    /// Zoom about a viewport-space anchor so the board point under the
    /// anchor stays put. Mutates `ptsPerMm` (not a scaleEffect) so the
    /// Canvas redraws crisply at every zoom level — same approach as the
    /// editor's `PhysicalCanvasView`.
    private func zoomBy(_ factor: Double, anchor: CGPoint) {
        let minScale = 1.0
        let maxScale = 200.0
        let next = max(minScale, min(maxScale, transform.ptsPerMm * factor))
        let actual = next / transform.ptsPerMm
        guard abs(actual - 1) > 0.0001 else { return }
        transform.offset = CGSize(
            width:  Double(anchor.x) - (Double(anchor.x) - transform.offset.width) * actual,
            height: Double(anchor.y) - (Double(anchor.y) - transform.offset.height) * actual
        )
        transform.ptsPerMm = next
        userAdjusted = true
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .local)
            .onChanged { value in
                if !bgDragging {
                    bgDragging = true
                    panBaseline = transform.offset
                }
                transform.offset = CGSize(
                    width: panBaseline.width + value.translation.width,
                    height: panBaseline.height + value.translation.height
                )
                userAdjusted = true
            }
            .onEnded { _ in bgDragging = false }
    }

    private func magnifyGesture(in viewSize: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if magnifyBaseline == nil {
                    magnifyBaseline = (transform.ptsPerMm, transform.offset)
                }
                guard let base = magnifyBaseline else { return }
                let anchor = anchorPoint(in: viewSize)
                let raw = max(0.05, value.magnification)
                let next = max(1.0, min(200.0, base.ptsPerMm * raw))
                let factor = next / base.ptsPerMm
                transform.offset = CGSize(
                    width:  Double(anchor.x) - (Double(anchor.x) - base.offset.width)  * factor,
                    height: Double(anchor.y) - (Double(anchor.y) - base.offset.height) * factor
                )
                transform.ptsPerMm = next
                userAdjusted = true
            }
            .onEnded { _ in magnifyBaseline = nil }
    }

    /// Fit the board outline into the viewport with a comfortable margin.
    /// Picks `ptsPerMm` directly so the rendering is sharp at the fit zoom
    /// level.
    private func fit(in viewSize: CGSize) {
        transform = CanvasTransform.fit(rect: document.physical.boardOutline, in: viewSize)
        userAdjusted = false
    }
}
