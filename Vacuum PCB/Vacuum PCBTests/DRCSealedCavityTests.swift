import Testing
import Foundation
@testable import Vacuum_PCB

/// `sealedCavity`: a piece of a net's *printed* channel network forms its own
/// sealed cavity — no channel, via, resistor or cross-silicone bridge joins
/// it to the rest of the net, and it has no external opening of its own.
///
/// The regression case is the "Incrementor 4bit" vent-tap fault (found on a
/// printed board, 2026-08-03): a parent route dead-ends 2 mm short of a
/// sub-part boundary pin. The logical connectivity check snaps route ends to
/// pins within a dimple radius (2.5 mm+), so ratsnest reads green — but the
/// print only heals gaps up to one channel diameter and drops boundary pins
/// entirely at flatten, so the tap prints sealed. This suite pins both halves
/// of that contract: the sealed fragment reports as an error, AND the
/// connectivity gate stays green (documenting the blind spot this check
/// exists to close — if connectivity ever learns to catch it, this test says
/// so and the two checks can be reconciled).
@MainActor
struct DRCSealedCavityTests {

    private let bottom0 = Layer(plate: .bottom, depth: 0)

    /// Child part: one transistor at (15,10) placed on top (pads drop on the
    /// bottom plate) with pin "a" routed on B0 to an atmVent at (5,10) — the
    /// vent tap pattern. Standalone, the child is fully connected.
    private func ventChild() -> (CircuitDocument, UUID) {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 30, height: 20))
        doc.skipEdgeWallDRC = true
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components.append(q)
        let pl = Placement(componentId: q.id, position: Point(x: 15, y: 10),
                           rotation: .r0, layer: .top, depth: 0)
        doc.physical.placements.append(pl)
        let vent = Component(kind: .atmVent, label: "V")
        doc.logic.components.append(vent)
        doc.physical.placements.append(Placement(
            componentId: vent.id, position: Point(x: 5, y: 10),
            rotation: .r0, layer: .bottom, depth: 0))
        let pinA = q.footprint(doc.manufacturing).pin("a")!
        let start = pl.worldPosition(of: pinA)
        let net = Net(label: "nV", pins: [
            PinRef(componentId: q.id, pinKey: "a"),
            PinRef(componentId: vent.id, pinKey: "p"),
        ])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [
                Waypoint(position: start),
                Waypoint(position: Point(x: start.x, y: 16)),
                Waypoint(position: Point(x: 5, y: 16)),
                Waypoint(position: Point(x: 5, y: 10)),
            ], layer: bottom0)
        ]))
        return (doc, vent.id)
    }

    /// Parent: the child as sub-part U1 at (20,10), its vent boundary pin
    /// re-plumbed to the parent's own VENT. `shortBy` stops the parent route
    /// that many mm short of the boundary pin's world position (25,20) —
    /// 0 routes clean, 2.0 reproduces the printed fault (inside the ratsnest
    /// snap tolerance of dimpleDiameter/2 + 0.01 ≈ 2.51, outside the
    /// channel-diameter print heal of 1.5).
    private func parent(shortBy: Double) -> CircuitDocument {
        let (child, childVentId) = ventChild()
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.skipEdgeWallDRC = true
        var sub = Component(kind: .subpart, label: "U1")
        sub.partRef = "vent-child.vpcb"
        sub.partRefHash = "h-vent"
        doc.logic.components.append(sub)
        doc.librarySnapshots["h-vent"] = child
        doc.physical.placements.append(Placement(
            componentId: sub.id, position: Point(x: 20, y: 10),
            rotation: .r0, layer: .top, depth: 0))
        let vent = Component(kind: .atmVent, label: "VENT")
        doc.logic.components.append(vent)
        doc.physical.placements.append(Placement(
            componentId: vent.id, position: Point(x: 10, y: 20),
            rotation: .r0, layer: .bottom, depth: 0))
        let net = Net(label: "nP", pins: [
            PinRef(componentId: sub.id, pinKey: childVentId.uuidString),
            PinRef(componentId: vent.id, pinKey: "p"),
        ])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [
                Waypoint(position: Point(x: 10, y: 20)),
                Waypoint(position: Point(x: 25 - shortBy, y: 20)),
            ], layer: bottom0)
        ]))
        return doc
    }

    private func sealedIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .sealedCavity = $0.kind { return true }
            return false
        }
    }

    @Test("route 2 mm short of the boundary pin seals the tap — error, ratsnest green")
    func routeShortOfBoundaryPinReports() {
        let doc = parent(shortBy: 2.0)
        let issues = sealedIssues(doc)
        #expect(issues.count == 1)
        var matched = false
        if case let .sealedCavity(refs, layer, _)? = issues.first?.kind {
            matched = true
            #expect(refs.contains("U1.Q1.a"))
            #expect(layer.plate == .bottom)
        }
        #expect(matched)
        #expect(issues.allSatisfy { $0.severity == .error })
        // The blind spot this check closes: the ratsnest union-find snaps
        // the 2 mm gap (pin-snap tolerance is a dimple radius), so it still
        // reports zero unrouted — but the connectivity gate now fails on the
        // sealed cavity instead of waving the board through.
        let conn = Validators.connectivity(doc)
        #expect(conn.unrouted == 0)
        #expect(!conn.pass)
    }

    @Test("route landing on the boundary pin stays silent")
    func routeOnBoundaryPinSilent() {
        #expect(sealedIssues(parent(shortBy: 0)).isEmpty)
    }

    @Test("the child standalone stays silent")
    func childStandaloneSilent() {
        #expect(sealedIssues(ventChild().0).isEmpty)
    }
}
