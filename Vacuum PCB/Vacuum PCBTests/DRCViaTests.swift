import Testing
import Foundation
@testable import Vacuum_PCB

/// DRC's `orphanVia` (a `.via` marked on a single layer, which PlateBuilder
/// never drills) must stay silent only for a *decorative* via sitting on a pin
/// of its OWN layer. A single-layer via landing on a pin of a different layer
/// is a genuine break and has to report — the `4bit register with bus` case
/// where a B1 via sat on the register's B0 pin and slipped through.
@MainActor
struct DRCViaTests {

    private func hasOrphanVia(_ doc: CircuitDocument) -> Bool {
        DRC.check(doc).contains { if case .orphanVia = $0.kind { return true }; return false }
    }

    @Test("Orphan via landing on a pin of the WRONG layer is reported")
    func orphanViaOnWrongLayerPinReported() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 30))
        doc.physical.bottomLayers = 2

        let mid = Component(kind: .port, label: "MID", portDirection: .input)
        let far = Component(kind: .port, label: "FAR", portDirection: .output)
        doc.logic.components = [mid, far]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: mid.id, pinKey: "p"),
            PinRef(componentId: far.id, pinKey: "p"),
        ])]
        doc.physical.placements = [
            Placement(componentId: mid.id, position: Point(x: 30, y: 15), rotation: .r0, layer: .bottom, depth: 0), // B0 pin
            Placement(componentId: far.id, position: Point(x: 60, y: 15), rotation: .r0, layer: .bottom, depth: 1), // B1 pin
        ]
        // A B1 segment whose via lands on MID's XY — but MID is a B0 pin, so the
        // B1 route never actually reaches it: still an orphan.
        let b1 = Layer(plate: .bottom, depth: 1)
        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [
            Segment(waypoints: [
                Waypoint(position: Point(x: 60, y: 15)),
                Waypoint(position: Point(x: 30, y: 15), kind: .via),
            ], layer: b1),
        ])]

        #expect(hasOrphanVia(doc))
    }

    @Test("Decorative via on a pin of its OWN layer is suppressed")
    func decorativeViaOnSameLayerPinSuppressed() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 30))

        let p = Component(kind: .port, label: "P", portDirection: .input)
        let q = Component(kind: .port, label: "Q", portDirection: .output)
        doc.logic.components = [p, q]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: p.id, pinKey: "p"),
            PinRef(componentId: q.id, pinKey: "p"),
        ])]
        doc.physical.placements = [
            Placement(componentId: p.id, position: Point(x: 20, y: 15), rotation: .r0, layer: .bottom, depth: 0),
            Placement(componentId: q.id, position: Point(x: 50, y: 15), rotation: .r0, layer: .bottom, depth: 0),
        ]
        // B0 segment connecting the pins, with a (harmless) via marker right on
        // P's own-layer pin.
        let b0 = Layer(plate: .bottom, depth: 0)
        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [
            Segment(waypoints: [
                Waypoint(position: Point(x: 20, y: 15), kind: .via),
                Waypoint(position: Point(x: 50, y: 15)),
            ], layer: b0),
        ])]

        #expect(!hasOrphanVia(doc))
    }
}
