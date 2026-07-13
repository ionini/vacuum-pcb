import SwiftUI

/// Drawing-bounds headroom for the schematic wire `Canvas`es (the editor's
/// `NetLinesView` and the Simulate `SchematicCanvasLayer`).
///
/// A SwiftUI `Canvas` clips its drawing to its own frame. Components can be
/// dragged to *negative* schematic coordinates (drag one left of the origin),
/// and they keep rendering because they're positioned views — but a wire drawn
/// at a negative coordinate would be clipped at the canvas's top-left edge and
/// vanish even though both its pins are on screen. So we give the canvas a big
/// frame centred on the schematic origin via `.offset` (a render-time transform
/// that doesn't grow the layout) and translate the drawing context by `origin`
/// to compensate. The net effect: schematic point (x, y) still draws at (x, y),
/// but the drawable region now spans ±`origin` in both axes.
enum SchematicCanvasBounds {
    static let extent: CGFloat = 200_000
    static var origin: CGFloat { extent / 2 }
}

/// Renders nets as one line per edge in a hybrid layout: nets that have a
/// natural endpoint (a port or a rail) get drawn as a star anchored on that
/// pin; nets that connect only components fall back to a minimum spanning
/// tree on pin positions. So a net like (Q2.b, R3.1, Q6.b) with no port
/// shows Q2—R3—Q6, with each pin connected to its nearest neighbour in the
/// tree, instead of every pin spoking from whichever happened to be first.
///
/// Selected nets stroke wider in the accent color. Connector matings draw
/// on top as chunky indigo bus-lines so they read as "these two
/// connectors snap together, all N pins in parallel" rather than getting
/// lost in the regular net mesh.
struct NetLinesView: View {
    let document: CircuitDocument
    let selection: SchematicSelection
    /// Net the cursor is currently over, highlighted brighter/wider than the
    /// resting state so the whole connection lights up on hover. Selection
    /// still wins when both apply.
    var hoveredNet: UUID? = nil
    /// When false, VAC/ATM nets draw as wires instead of tap symbols.
    var railTaps: Bool = true
    /// When true, draw a small marker + name on each net that has a physical
    /// testing point. Hideable via the schematic toolbar toggle.
    var showTestPoints: Bool = true
    /// Live drag displacement folded into the dragged components' positions so
    /// the wires follow the moving symbols instead of snapping only on release.
    /// Nil when nothing is being dragged.
    var dragShift: SchematicDragShift? = nil

    /// `document` with any in-flight drag displacement applied to the dragged
    /// components. Copy-on-write means only the positions array is duplicated —
    /// `librarySnapshots` and everything else stay shared. Returns `document`
    /// unchanged when no drag is active.
    private var draggedDocument: CircuitDocument {
        guard let shift = dragShift, !shift.participants.isEmpty else { return document }
        var doc = document
        for id in shift.participants {
            guard let p = doc.schematic.position(for: id) else { continue }
            doc.schematic.setPosition(
                Point(x: p.x + shift.translation.width, y: p.y + shift.translation.height),
                for: id
            )
        }
        // Carry the bend points of fully-participating wires along too, so a
        // routed wire keeps its shape mid-drag instead of kinking toward a
        // stale waypoint. Unsnapped for a smooth preview; the commit snaps.
        doc.schematic.translateWaypoints(
            forComponentsIn: shift.participants, by: shift.translation, snap: false
        )
        return doc
    }

    var body: some View {
        Canvas { ctx, _ in
            // Centre the drawing on the schematic origin so wires to pins at
            // negative coordinates aren't clipped at the canvas edge. See
            // `SchematicCanvasBounds`.
            ctx.translateBy(x: SchematicCanvasBounds.origin, y: SchematicCanvasBounds.origin)
            let document = draggedDocument
            let nets = SchematicWireGeometry.render(in: document, railTaps: railTaps)

            // Wires + rail taps.
            for net in nets {
                let style = netStroke(for: net.netId)
                for edge in net.edges {
                    ctx.stroke(
                        WireRouter.roundedPath(edge.points, radius: 9),
                        with: .color(style.color),
                        style: StrokeStyle(lineWidth: style.width, lineCap: .round, lineJoin: .round)
                    )
                }
                for tap in net.taps {
                    drawTap(ctx, tap, highlighted: isHighlighted(net.netId))
                }
            }

            // Break crossings of different nets with a hop so it's clear they
            // don't connect, then dot the real junctions.
            drawHops(ctx, nets)
            drawJunctionDots(ctx, nets)
            drawTestPoints(ctx, nets)

            // Connector matings: chunky indigo bus-lines on top.
            for mating in document.logic.matings {
                guard let a = MatingEndpointGeometry.point(for: mating.a, in: document),
                      let b = MatingEndpointGeometry.point(for: mating.b, in: document)
                else { continue }
                let da = MatingEndpointGeometry.exit(for: mating.a, selfPoint: a, otherPoint: b, in: document)
                let db = MatingEndpointGeometry.exit(for: mating.b, selfPoint: b, otherPoint: a, in: document)
                ctx.stroke(
                    WireRouter.roundedPath(WireRouter.route(from: a, da, to: b, db), radius: 9),
                    with: .color(.indigo.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
        // Oversized, origin-centred frame so the canvas can draw into negative
        // schematic space without clipping (see `SchematicCanvasBounds`). The
        // `.offset` is render-only, so it doesn't blow up the layout frame.
        .frame(width: SchematicCanvasBounds.extent, height: SchematicCanvasBounds.extent)
        .offset(x: -SchematicCanvasBounds.origin, y: -SchematicCanvasBounds.origin)
        .allowsHitTesting(false)
    }

    private func isHighlighted(_ netId: UUID) -> Bool {
        selection.contains(net: netId) || netId == hoveredNet
    }

    /// Resting / hovered / selected stroke for a net. Selection is the
    /// strongest signal (full accent, widest); hover is a lighter accent so it
    /// reads as "this is what you'd select"; everything else is the quiet
    /// secondary rat's-nest line.
    private func netStroke(for netId: UUID) -> (color: Color, width: CGFloat) {
        if selection.contains(net: netId) { return (.accentColor, 2.5) }
        if netId == hoveredNet { return (.accentColor.opacity(0.55), 2.0) }
        return (.secondary, 1.2)
    }

    // MARK: - Rail taps

    /// Draws one rail tap: a short stub out of the pin ending in a perpendicular
    /// bar (the rail symbol) with a VAC/ATM label, in the rail's colour.
    private func drawTap(_ ctx: GraphicsContext, _ tap: SchematicWireGeometry.Tap, highlighted: Bool) {
        let stub: CGFloat = 12, half: CGFloat = 7
        let p = tap.point
        let v = tap.exit.vector
        let end = CGPoint(x: p.x + v.x * stub, y: p.y + v.y * stub)
        let perp = tap.exit.isHorizontal ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        let railColor: Color = tap.rail == .vacuumSource ? .red : .green
        let lineColor: Color = highlighted ? .accentColor : railColor.opacity(0.85)
        let w: CGFloat = highlighted ? 2.2 : 1.6

        var stubPath = Path()
        stubPath.move(to: p)
        stubPath.addLine(to: end)
        ctx.stroke(stubPath, with: .color(lineColor), style: StrokeStyle(lineWidth: w, lineCap: .round))

        var bar = Path()
        bar.move(to: CGPoint(x: end.x - perp.x * half, y: end.y - perp.y * half))
        bar.addLine(to: CGPoint(x: end.x + perp.x * half, y: end.y + perp.y * half))
        ctx.stroke(bar, with: .color(lineColor), style: StrokeStyle(lineWidth: w + 0.4, lineCap: .round))

        var text = ctx.resolve(Text(tap.rail == .vacuumSource ? "VAC" : "ATM")
            .font(.system(size: 9, weight: .medium)))
        text.shading = .color(railColor)
        ctx.draw(text, at: CGPoint(x: end.x + v.x * 9, y: end.y + v.y * 9), anchor: .center)
    }

    // MARK: - Testing points

    /// Draws a small marker + name for every physical testing point, anchored
    /// on the tapped net's wire. The physical mid-route position has no
    /// correspondence in schematic space, so the anchor is cosmetic: markers
    /// sit along the net's longest edge, spread out when a net has several.
    private func drawTestPoints(_ ctx: GraphicsContext, _ nets: [SchematicWireGeometry.NetRender]) {
        guard showTestPoints, !document.physical.testPoints.isEmpty else { return }
        var byNet: [UUID: [TestPoint]] = [:]
        for tp in document.physical.testPoints { byNet[tp.netId, default: []].append(tp) }
        let renderByNet = Dictionary(nets.map { ($0.netId, $0) }, uniquingKeysWith: { a, _ in a })
        for (netId, tps) in byNet {
            guard let net = renderByNet[netId],
                  let edge = net.edges.max(by: { polylineLength($0.points) < polylineLength($1.points) }),
                  edge.points.count >= 2 else { continue }
            for (idx, tp) in tps.enumerated() {
                let frac = tps.count == 1
                    ? 0.5
                    : 0.3 + 0.4 * Double(idx) / Double(tps.count - 1)
                let (pt, dir) = pointAndDirection(along: edge.points, fraction: frac)
                let perp = CGPoint(x: -dir.y, y: dir.x)
                let center = CGPoint(x: pt.x + perp.x * 11, y: pt.y + perp.y * 11)
                drawTestPointMarker(ctx, at: center, stubFrom: pt,
                                    name: tp.name, highlighted: isHighlighted(netId))
            }
        }
    }

    private func drawTestPointMarker(
        _ ctx: GraphicsContext, at c: CGPoint, stubFrom p: CGPoint,
        name: String, highlighted: Bool
    ) {
        let color: Color = highlighted ? .accentColor : .orange
        var stub = Path()
        stub.move(to: p)
        stub.addLine(to: c)
        ctx.stroke(stub, with: .color(color.opacity(0.7)),
                   style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        let r: CGFloat = 4
        ctx.stroke(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                   with: .color(color), style: StrokeStyle(lineWidth: 1.6))
        ctx.fill(Path(ellipseIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)),
                 with: .color(color))
        var text = ctx.resolve(Text(name).font(.system(size: 8, weight: .medium)))
        text.shading = .color(color)
        ctx.draw(text, at: CGPoint(x: c.x, y: c.y - r - 6), anchor: .center)
    }

    private func polylineLength(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        var total: CGFloat = 0
        for i in 0..<(pts.count - 1) { total += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y) }
        return total
    }

    /// Point and unit direction at `fraction` of the polyline's length.
    private func pointAndDirection(along pts: [CGPoint], fraction: Double) -> (CGPoint, CGPoint) {
        let target = polylineLength(pts) * CGFloat(fraction)
        var acc: CGFloat = 0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            if len <= 0 { continue }
            if acc + len >= target {
                let t = (target - acc) / len
                return (CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t),
                        CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len))
            }
            acc += len
        }
        let a = pts[pts.count - 2], b = pts[pts.count - 1]
        let len = max(hypot(b.x - a.x, b.y - a.y), 0.0001)
        return (b, CGPoint(x: (b.x - a.x) / len, y: (b.y - a.y) / len))
    }

    // MARK: - Junction dots

    /// A filled dot wherever 3+ wire segments of one net meet — the unambiguous
    /// "these are joined" marker (a 2-way meeting is just a corner).
    private func drawJunctionDots(_ ctx: GraphicsContext, _ nets: [SchematicWireGeometry.NetRender]) {
        for net in nets {
            var degree: [PinRef: Int] = [:]
            var pointFor: [PinRef: CGPoint] = [:]
            for e in net.edges {
                degree[e.a, default: 0] += 1
                degree[e.b, default: 0] += 1
                if let f = e.points.first { pointFor[e.a] = f }
                if let l = e.points.last { pointFor[e.b] = l }
            }
            let color = netStroke(for: net.netId).color
            for (pin, d) in degree where d >= 3 {
                guard let c = pointFor[pin] else { continue }
                let r: CGFloat = 3
                ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color))
            }
        }
    }

    // MARK: - Crossing hops

    /// Where an orthogonal segment of one net crosses one of another net, break
    /// the under-wire with a small background gap and redraw the over-wire's
    /// local piece, so a crossing reads as "passes over", not "connects".
    private func drawHops(_ ctx: GraphicsContext, _ nets: [SchematicWireGeometry.NetRender]) {
        struct Seg { let netIndex: Int; let netId: UUID; let a: CGPoint; let b: CGPoint }
        var segs: [Seg] = []
        for (i, net) in nets.enumerated() {
            for e in net.edges where e.points.count >= 2 {
                for k in 0..<(e.points.count - 1) {
                    segs.append(Seg(netIndex: i, netId: net.netId, a: e.points[k], b: e.points[k + 1]))
                }
            }
        }
        func horizontal(_ s: Seg) -> Bool { abs(s.a.y - s.b.y) < 0.5 }

        for i in 0..<segs.count {
            for j in (i + 1)..<segs.count {
                let s = segs[i], t = segs[j]
                guard s.netId != t.netId, horizontal(s) != horizontal(t) else { continue }
                let h = horizontal(s) ? s : t
                let vSeg = horizontal(s) ? t : s
                let x = vSeg.a.x, y = h.a.y
                let hx0 = min(h.a.x, h.b.x), hx1 = max(h.a.x, h.b.x)
                let vy0 = min(vSeg.a.y, vSeg.b.y), vy1 = max(vSeg.a.y, vSeg.b.y)
                guard x > hx0 + 2, x < hx1 - 2, y > vy0 + 2, y < vy1 - 2 else { continue }

                let g: CGFloat = 4
                ctx.fill(Path(ellipseIn: CGRect(x: x - g, y: y - g, width: 2 * g, height: 2 * g)),
                         with: .color(Color.canvasBackground))
                let overVertical = vSeg.netIndex > h.netIndex
                let over = overVertical ? vSeg : h
                let stroke = netStroke(for: over.netId)
                var piece = Path()
                if overVertical {
                    piece.move(to: CGPoint(x: x, y: y - g - 1))
                    piece.addLine(to: CGPoint(x: x, y: y + g + 1))
                } else {
                    piece.move(to: CGPoint(x: x - g - 1, y: y))
                    piece.addLine(to: CGPoint(x: x + g + 1, y: y))
                }
                ctx.stroke(piece, with: .color(stroke.color), style: StrokeStyle(lineWidth: stroke.width, lineCap: .round))
            }
        }
    }
}

/// Maps a `ConnectorEndpoint` to its visible position on the schematic
/// canvas — the centre of the connector symbol for top-level endpoints,
/// or the centre of the socket tab on the subpart symbol for subpart
/// sockets. Used by `NetLinesView` to draw mating bus-lines and by the
/// inspector for "Mated to" labels.
enum MatingEndpointGeometry {
    static func point(for endpoint: ConnectorEndpoint, in document: CircuitDocument) -> CGPoint? {
        switch endpoint {
        case .topLevel(let id):
            guard let comp = document.logic.components.first(where: { $0.id == id }),
                  comp.kind == .connector,
                  let pos = document.schematic.position(for: id)
            else { return nil }
            _ = comp
            return CGPoint(x: pos.x, y: pos.y)
        case .subpartSocket(let subpartId, let connectorId):
            guard let subpart = document.logic.components.first(where: { $0.id == subpartId }),
                  subpart.kind == .subpart,
                  let pos = document.schematic.position(for: subpartId)
            else { return nil }
            let metrics = ComponentSymbolMetrics
                .metrics(for: subpart, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: subpartId))
            guard let layout = metrics.sockets.first(where: { $0.connectorId == connectorId })
            else { return nil }
            return CGPoint(x: pos.x + layout.centre.x, y: pos.y + layout.centre.y)
        }
    }

    /// Direction the mating bus-line should leave an endpoint. A subpart
    /// socket leaves perpendicular to the (rotated) edge it sits on; a
    /// top-level connector centre — which has no natural side — heads straight
    /// toward the other endpoint.
    static func exit(
        for endpoint: ConnectorEndpoint,
        selfPoint: CGPoint,
        otherPoint: CGPoint,
        in document: CircuitDocument
    ) -> ExitDir {
        if case .subpartSocket(let subpartId, let connectorId) = endpoint,
           let subpart = document.logic.components.first(where: { $0.id == subpartId }),
           subpart.kind == .subpart {
            let metrics = ComponentSymbolMetrics
                .metrics(for: subpart, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: subpartId))
            if let layout = metrics.sockets.first(where: { $0.connectorId == connectorId }) {
                return ExitDir(side: layout.side)
            }
        }
        return ExitDir.from(CGPoint(x: otherPoint.x - selfPoint.x, y: otherPoint.y - selfPoint.y))
    }
}
