import SwiftUI

/// Single source of truth for how each net is drawn on the schematic. A net is
/// rendered either as a set of routed orthogonal polylines (with lane
/// spreading, obstacle avoidance, and any user waypoints baked in) or — for
/// vacuum/vent rail nets — as a compact tap glyph at each pin instead of long
/// spokes. Both the renderers (`NetLinesView`, `SimulateSchematicCanvas`) and
/// the canvas hit-tests build from this, so they always agree on wire shape.
enum SchematicWireGeometry {
    /// A rail "tap" at one pin: leave the pin along `exit`, draw a small rail
    /// bar, and label it. Replaces long spokes for VAC/ATM nets.
    struct Tap {
        let pin: PinRef
        let point: CGPoint
        let exit: ExitDir
        let rail: ComponentKind          // .vacuumSource or .atmVent
    }
    /// One drawn wire between two pins, fully routed to its final polyline.
    struct RoutedEdge {
        let a: PinRef
        let b: PinRef
        let points: [CGPoint]
    }
    struct NetRender {
        let netId: UUID
        let edges: [RoutedEdge]
        let taps: [Tap]
    }

    /// `railTaps == false` draws VAC/ATM nets as ordinary wires (a star from
    /// the rail source) instead of per-pin tap symbols — the user toggle.
    static func render(in document: CircuitDocument, railTaps: Bool = true) -> [NetRender] {
        let geo = NetEdgeBuilder.pinGeometry(in: document)
        let rects = obstacleRects(in: document)
        return document.logic.nets.enumerated().map { index, net in
            if railTaps, let rail = railKind(for: net, in: document) {
                let taps = net.pins.compactMap { ref -> Tap? in
                    geo[ref].map { Tap(pin: ref, point: $0.point, exit: $0.exit, rail: rail) }
                }
                return NetRender(netId: net.id, edges: [], taps: taps)
            }
            let lane = laneOffset(forNetAt: index)
            let edges = NetEdgeBuilder.edges(for: net, in: document, geometry: geo).map { e in
                let obstacles = rects
                    .filter { $0.0 != e.a.pin.componentId && $0.0 != e.b.pin.componentId }
                    .map(\.1)
                let waypoints = document.schematic.waypoints(e.a.pin, e.b.pin)
                    .map { CGPoint(x: $0.x, y: $0.y) }
                let points = WireRouter.route(
                    from: e.a.point, e.a.exit, to: e.b.point, e.b.exit,
                    waypoints: waypoints, obstacles: obstacles, laneOffset: lane
                )
                return RoutedEdge(a: e.a.pin, b: e.b.pin, points: points)
            }
            return NetRender(netId: net.id, edges: edges, taps: [])
        }
    }

    /// Rail kind a net should tap to, or nil if it should stay wired. A net
    /// with a port keeps explicit wires (the port is its natural anchor);
    /// otherwise a vacuum/vent pin turns the whole net into rail taps.
    static func railKind(for net: Net, in document: CircuitDocument) -> ComponentKind? {
        func kind(_ ref: PinRef) -> ComponentKind? {
            document.logic.components.first(where: { $0.id == ref.componentId })?.kind
        }
        if net.pins.contains(where: { kind($0) == .port }) { return nil }
        if net.pins.contains(where: { kind($0) == .vacuumSource }) { return .vacuumSource }
        if net.pins.contains(where: { kind($0) == .atmVent }) { return .atmVent }
        return nil
    }

    /// Component bounding rects (rotated, slightly inflated) used as routing
    /// obstacles. Screws never reach the schematic.
    static func obstacleRects(in document: CircuitDocument) -> [(UUID, CGRect)] {
        let inset: CGFloat = 4
        return document.logic.components.compactMap { c in
            guard c.kind != .screw, let p = document.schematic.position(for: c.id) else { return nil }
            let m = ComponentSymbolMetrics
                .metrics(for: c, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: c.id))
            let rect = CGRect(
                x: CGFloat(p.x) - m.size.width / 2 - inset,
                y: CGFloat(p.y) - m.size.height / 2 - inset,
                width: m.size.width + 2 * inset,
                height: m.size.height + 2 * inset
            )
            return (c.id, rect)
        }
    }

    /// Deterministic per-net lane offset so different nets' parallel trunk runs
    /// spread across distinct lanes instead of stacking on the same line.
    /// Keyed by net order, so it's stable across renders (no jitter).
    static func laneOffset(forNetAt index: Int) -> CGFloat {
        let lanes = 5
        return CGFloat((index % lanes) - lanes / 2) * 7
    }
}
