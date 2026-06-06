import Testing
import Foundation
@testable import Vacuum_PCB

/// Multi-layer routing: the auto-router must connect a net whose pins live on
/// different channel depths of the same plate, dropping an intra-plate via.
@MainActor
struct AutoRouterTests {

    private func route(_ doc: inout CircuitDocument) {
        for entry in AutoRouter.plan(doc) {
            if let i = doc.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                doc.physical.routes[i].segments.append(entry.segment)
            } else {
                doc.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }

    @Test("Routes a net across two depths of one plate, via an intra-plate via")
    func routesAcrossDepths() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 40, height: 30))
        doc.physical.topLayers = 2   // depth 0 + depth 1 on the top plate

        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        doc.logic.components = [r1, r2]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: r1.id, pinKey: "2"),
            PinRef(componentId: r2.id, pinKey: "1"),
        ])]
        doc.physical.placements = [
            Placement(componentId: r1.id, position: Point(x: 10, y: 15), rotation: .r0, layer: .top, depth: 0),
            Placement(componentId: r2.id, position: Point(x: 28, y: 15), rotation: .r0, layer: .top, depth: 1),
        ]

        route(&doc)

        // Net is fully connected (no disconnected pins / unrouted net).
        let issues = DRC.check(doc)
        let broken = issues.contains {
            switch $0.kind {
            case .disconnectedPin, .noRouteDrawn: return true
            default: return false
            }
        }
        #expect(!broken)

        // The routing actually used both depths — i.e. it dropped a via from
        // depth 0 up to depth 1 rather than failing to bridge them.
        let depths = Set(doc.physical.routes.flatMap { $0.segments.map(\.layer.depth) })
        let usedBothDepths = depths.contains(0) && depths.contains(1)
        #expect(usedBothDepths)
    }

    private func routeNegotiated(_ doc: inout CircuitDocument, ripUp: Set<UUID>? = nil) {
        for entry in AutoRouter.planNegotiated(doc, ripUp: ripUp) {
            if let i = doc.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                doc.physical.routes[i].segments.append(entry.segment)
            } else {
                doc.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }

    private func routingBroken(_ doc: CircuitDocument) -> Bool {
        DRC.check(doc).contains {
            switch $0.kind {
            case .disconnectedPin, .noRouteDrawn: return true
            default: return false
            }
        }
    }

    @Test("Negotiated router connects a small multi-net board cleanly")
    func negotiatedRoutesCleanly() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        doc.logic.components = [vac, r1, r2, out]
        doc.logic.nets = [
            Net(label: "n1", pins: [PinRef(componentId: vac.id, pinKey: "p"), PinRef(componentId: r1.id, pinKey: "1")]),
            Net(label: "n2", pins: [PinRef(componentId: r1.id, pinKey: "2"), PinRef(componentId: r2.id, pinKey: "1")]),
            Net(label: "n3", pins: [PinRef(componentId: r2.id, pinKey: "2"), PinRef(componentId: out.id, pinKey: "p")]),
        ]
        // Resistor footprints are 12 mm long, so space the centres well apart.
        doc.physical.placements = [
            Placement(componentId: vac.id, position: Point(x: 8, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: r1.id, position: Point(x: 26, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: r2.id, position: Point(x: 50, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 72, y: 20), rotation: .r0, layer: .top),
        ]
        routeNegotiated(&doc)
        #expect(!routingBroken(doc))
    }

    @Test("Incremental rip-up re-routes only the named nets, leaving others intact")
    func ripUpPreservesOtherRoutes() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 40))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        doc.logic.components = [vac, r1, out]
        let n1 = Net(label: "n1", pins: [PinRef(componentId: vac.id, pinKey: "p"), PinRef(componentId: r1.id, pinKey: "1")])
        let n2 = Net(label: "n2", pins: [PinRef(componentId: r1.id, pinKey: "2"), PinRef(componentId: out.id, pinKey: "p")])
        doc.logic.nets = [n1, n2]
        doc.physical.placements = [
            Placement(componentId: vac.id, position: Point(x: 8, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: r1.id, position: Point(x: 24, y: 20), rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: Point(x: 42, y: 20), rotation: .r0, layer: .top),
        ]
        routeNegotiated(&doc)
        let n2Before = doc.physical.routes.first { $0.netId == n2.id }

        // Rip up only n1; n2's route must be byte-identical afterwards.
        doc.physical.routes.removeAll { $0.netId == n1.id }
        routeNegotiated(&doc, ripUp: [n1.id])
        let n2After = doc.physical.routes.first { $0.netId == n2.id }
        let preserved = n2Before == n2After
        #expect(preserved)
        #expect(!routingBroken(doc))
    }
}

/// The clearance DRC checks added for the minimiser's hard constraints:
/// screws vs fluid features, and via spacing.
@MainActor
struct DRCClearanceTests {

    private func hasScrewClearance(_ issues: [DRC.Issue]) -> Bool {
        issues.contains { if case .screwClearance = $0.kind { return true }; return false }
    }
    private func hasViaSpacing(_ issues: [DRC.Issue]) -> Bool {
        issues.contains { if case .viaSpacing = $0.kind { return true }; return false }
    }

    /// A vacuum→port net routed as one straight top-layer segment, with a screw
    /// placed at a chosen point. Used to probe screw-vs-channel clearance.
    private func screwOnRoute(screwAt screw: Point) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 30))
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        let sc = Component(kind: .screw, label: "S1")
        doc.logic.components = [vac, out, sc]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: vac.id, pinKey: "p"), PinRef(componentId: out.id, pinKey: "p"),
        ])]
        let a = Point(x: 10, y: 15), b = Point(x: 50, y: 15)
        doc.physical.placements = [
            Placement(componentId: vac.id, position: a, rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: b, rotation: .r0, layer: .top),
            Placement(componentId: sc.id, position: screw, rotation: .r0, layer: .top),
        ]
        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: Layer(plate: .top, depth: 0)),
        ])]
        return doc
    }

    @Test("A screw sitting on a channel trips screwClearance; one well clear does not")
    func screwClearanceFiresWhenClose() {
        #expect(hasScrewClearance(DRC.check(screwOnRoute(screwAt: Point(x: 30, y: 15)))))   // on the line
        #expect(!hasScrewClearance(DRC.check(screwOnRoute(screwAt: Point(x: 30, y: 28)))))  // 13 mm away
    }

    /// A horizontal channel at `routeLayer` with a screw `offset` mm to its
    /// side (the perpendicular gap to the segment is exactly `offset`). Knobs
    /// expose the Z-dependent inputs: the head-side plate, the protrusion
    /// (which retracts the wide head/nut out of the plate), and the per-plate
    /// layer counts (which push deeper layers away from the outer-face
    /// cavities). Default manufacturing: head Ø5.1, hex 4.1 AF, shaft Ø2.2,
    /// channel Ø1.5, minWall 0.5.
    private func screwNearRoute(
        offset: Double, routeLayer: Layer,
        protrusion: Double = 0, headSide: Plate = .top,
        topLayers: Int = 1, bottomLayers: Int = 1
    ) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 30))
        doc.manufacturing.screwProtrusion = protrusion
        doc.physical.topLayers = topLayers
        doc.physical.bottomLayers = bottomLayers
        let vac = Component(kind: .vacuumSource, label: "VAC")
        let out = Component(kind: .port, label: "OUT", portDirection: .output)
        let sc = Component(kind: .screw, label: "S1")
        doc.logic.components = [vac, out, sc]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: vac.id, pinKey: "p"), PinRef(componentId: out.id, pinKey: "p"),
        ])]
        let a = Point(x: 10, y: 15), b = Point(x: 50, y: 15)
        doc.physical.placements = [
            Placement(componentId: vac.id, position: a, rotation: .r0, layer: .top),
            Placement(componentId: out.id, position: b, rotation: .r0, layer: .top),
            Placement(componentId: sc.id, position: Point(x: 30, y: 15 + offset), rotation: .r0, layer: headSide),
        ]
        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: routeLayer),
        ])]
        return doc
    }

    @Test("Protrusion retracts the head out of the plate, so the shaft — not the wide head — sets the wall")
    func screwClearanceUsesShaftWhenHeadProtrudes() {
        let top0 = Layer(plate: .top, depth: 0)
        // 3.5 mm to the side: the 2.55 mm head countersink (flush, prot 0)
        // leaves a 0.2 mm wall and trips; once the head rides 3 mm up into a
        // volcano dome it clears the channel's depth and only the 1.1 mm
        // shaft remains beside it (1.65 mm wall), so the warning goes away.
        #expect(hasScrewClearance(DRC.check(screwNearRoute(offset: 3.5, routeLayer: top0, protrusion: 0))))
        #expect(!hasScrewClearance(DRC.check(screwNearRoute(offset: 3.5, routeLayer: top0, protrusion: 3))))
    }

    @Test("A buried channel clears the outer-face cavities; the outermost layer at the same offset still trips")
    func screwClearanceIsDepthAware() {
        // Two-layer bottom plate, nut pocket sunk from the outer face. At
        // 3 mm to the side the depth-1 channel (outermost, beside the nut)
        // trips, while the depth-0 channel (buried near the silicone, far from
        // the pocket) sees only the narrow shaft and clears — a distinction the
        // old Z-blind check, which used the head radius for both, couldn't make.
        let deep = Layer(plate: .bottom, depth: 0)
        let outer = Layer(plate: .bottom, depth: 1)
        #expect(hasScrewClearance(DRC.check(screwNearRoute(offset: 3.0, routeLayer: outer, bottomLayers: 2))))
        #expect(!hasScrewClearance(DRC.check(screwNearRoute(offset: 3.0, routeLayer: deep, bottomLayers: 2))))
    }

    /// Two different-net routes that each drop a `.via` waypoint, the vias a
    /// chosen distance apart on the top plate.
    private func twoVias(_ gap: Double) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 40))
        let a1 = Component(kind: .vacuumSource, label: "A1")
        let a2 = Component(kind: .port, label: "A2", portDirection: .output)
        let b1 = Component(kind: .vacuumSource, label: "B1")
        let b2 = Component(kind: .port, label: "B2", portDirection: .output)
        doc.logic.components = [a1, a2, b1, b2]
        let na = Net(label: "na", pins: [PinRef(componentId: a1.id, pinKey: "p"), PinRef(componentId: a2.id, pinKey: "p")])
        let nb = Net(label: "nb", pins: [PinRef(componentId: b1.id, pinKey: "p"), PinRef(componentId: b2.id, pinKey: "p")])
        doc.logic.nets = [na, nb]
        doc.physical.placements = [
            Placement(componentId: a1.id, position: Point(x: 5, y: 10), rotation: .r0, layer: .top),
            Placement(componentId: a2.id, position: Point(x: 25, y: 10), rotation: .r0, layer: .top),
            Placement(componentId: b1.id, position: Point(x: 5, y: 30), rotation: .r0, layer: .top),
            Placement(componentId: b2.id, position: Point(x: 25, y: 30), rotation: .r0, layer: .top),
        ]
        let layer = Layer(plate: .top, depth: 0)
        let viaA = Point(x: 20, y: 20)
        let viaB = Point(x: 20 + gap, y: 20)
        doc.physical.routes = [
            Route(netId: na.id, segments: [Segment(
                waypoints: [Waypoint(position: Point(x: 5, y: 10)), Waypoint(position: viaA, kind: .via)], layer: layer)]),
            Route(netId: nb.id, segments: [Segment(
                waypoints: [Waypoint(position: Point(x: 5, y: 30)), Waypoint(position: viaB, kind: .via)], layer: layer)]),
        ]
        return doc
    }

    @Test("Two foreign-net vias that nearly touch trip viaSpacing; spaced ones don't")
    func viaSpacingFiresWhenClose() {
        #expect(hasViaSpacing(DRC.check(twoVias(0.5))))   // walls overlap
        #expect(!hasViaSpacing(DRC.check(twoVias(6.0))))  // comfortably apart
    }
}
