import Testing
import Foundation
@testable import Vacuum_PCB

/// The ratsnest must reflect *physical* connectivity, not just coincident XY.
/// An "orphan" via — a `.via` marker on a single layer, which PlateBuilder
/// silently drops because it only cuts a bore where ≥2 layers meet — leaves
/// the net electrically open, so the dashed missing-edge hint has to stay up
/// rather than reporting the net as routed.
@MainActor
struct RatsnestTests {

    /// Two resistors on B0 wired through a B1 detour:
    ///   pinA ──B0── via(v1, B0↔B1) ──B1── (v2) ──B0── pinB
    /// The good via at `v1` is paired across both layers. The return point at
    /// `v2` is paired only when `returnViaPaired`; otherwise its `.via` marker
    /// lives on the B1 segment alone (orphan), so B1 never returns to B0.
    private func makeDoc(returnViaPaired: Bool) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 30))
        doc.physical.bottomLayers = 2   // B0 (depth 0) + B1 (depth 1)

        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        doc.logic.components = [r1, r2]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: r1.id, pinKey: "2"),
            PinRef(componentId: r2.id, pinKey: "1"),
        ])]
        let p1 = Placement(componentId: r1.id, position: Point(x: 8, y: 15), rotation: .r0, layer: .bottom, depth: 0)
        let p2 = Placement(componentId: r2.id, position: Point(x: 52, y: 15), rotation: .r0, layer: .bottom, depth: 0)
        doc.physical.placements = [p1, p2]

        // Resolve the two pin world positions exactly the way Ratsnest does, so
        // the route ends snap to them regardless of the resistor body length.
        let pA = p1.worldPosition(of: r1.footprint(doc.manufacturing).pin("2")!)
        let pB = p2.worldPosition(of: r2.footprint(doc.manufacturing).pin("1")!)

        let b0 = Layer(plate: .bottom, depth: 0)
        let b1 = Layer(plate: .bottom, depth: 1)
        let v1 = Point(x: 25, y: 15)   // good via, paired B0↔B1
        let v2 = Point(x: 35, y: 15)   // return point, paired only when asked

        let seg0 = Segment(waypoints: [
            Waypoint(position: pA),
            Waypoint(position: v1, kind: .via),
        ], layer: b0)
        let seg1 = Segment(waypoints: [
            Waypoint(position: v1, kind: .via),
            Waypoint(position: v2, kind: .via),
        ], layer: b1)
        let seg2 = Segment(waypoints: [
            Waypoint(position: v2, kind: returnViaPaired ? .via : .point),
            Waypoint(position: pB),
        ], layer: b0)

        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [seg0, seg1, seg2])]
        return doc
    }

    @Test("Orphan via (marked on one layer only) keeps the net in the ratsnest")
    func orphanViaLeavesNetUnrouted() {
        let doc = makeDoc(returnViaPaired: false)
        let edges = Ratsnest.missingEdges(doc)
        #expect(edges.contains { $0.netLabel == "n1" })
    }

    @Test("Pairing the via on both layers routes the net (no ratsnest edge)")
    func pairedViaCompletesNet() {
        let doc = makeDoc(returnViaPaired: true)
        let edges = Ratsnest.missingEdges(doc)
        #expect(!edges.contains { $0.netLabel == "n1" })
    }

    /// The case that bit `4bit register with bus`: the orphan via sits exactly
    /// on a pin, but on the *other* layer than the pin. A pin must not be
    /// treated as a layer junction — its bore only anchors its own layer — so
    /// the B1 segment is still severed from the B0 pin and the net stays in the
    /// ratsnest. (A naive "a pin bridges all layers at its XY" rule hides this.)
    @Test("An orphan via landing on a pin of the wrong layer still shows as unrouted")
    func orphanViaOnPinDoesNotMaskBreak() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 30))
        doc.physical.bottomLayers = 2

        // Three ports on B0: A ── (B0) ── MID, and C reached only through a B1
        // detour whose return via lands on MID — but marked on B1 only.
        let pA = Component(kind: .port, label: "A", portDirection: .input)
        let pMid = Component(kind: .port, label: "MID", portDirection: .input)
        let pC = Component(kind: .port, label: "C", portDirection: .output)
        doc.logic.components = [pA, pMid, pC]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: pA.id, pinKey: "p"),
            PinRef(componentId: pMid.id, pinKey: "p"),
            PinRef(componentId: pC.id, pinKey: "p"),
        ])]
        // Port pin "p" is at offset .zero, so world position == placement.
        let aPos = Point(x: 6, y: 15)
        let midPos = Point(x: 30, y: 15)
        let cPos = Point(x: 64, y: 15)
        doc.physical.placements = [
            Placement(componentId: pA.id, position: aPos, rotation: .r0, layer: .bottom, depth: 0),
            Placement(componentId: pMid.id, position: midPos, rotation: .r0, layer: .bottom, depth: 0),
            Placement(componentId: pC.id, position: cPos, rotation: .r0, layer: .bottom, depth: 0),
        ]

        let b0 = Layer(plate: .bottom, depth: 0)
        let b1 = Layer(plate: .bottom, depth: 1)
        let vGood = Point(x: 48, y: 15)   // properly paired B0↔B1

        // A ── MID on B0.
        let segA = Segment(waypoints: [Waypoint(position: aPos), Waypoint(position: midPos)], layer: b0)
        // C ── vGood on B0, then vGood ── MID on B1 with an orphan via at MID.
        let segC = Segment(waypoints: [Waypoint(position: cPos), Waypoint(position: vGood, kind: .via)], layer: b0)
        let segDetour = Segment(waypoints: [
            Waypoint(position: vGood, kind: .via),
            Waypoint(position: midPos, kind: .via),   // orphan: B1 marker on MID, which is a B0 pin
        ], layer: b1)
        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [segA, segC, segDetour])]

        // C is cut off: the B1 detour never returns to B0 at MID.
        #expect(Ratsnest.missingEdges(doc).contains { $0.netLabel == "n1" })

        // Pairing the via at MID on B0 (mark segA's MID endpoint) heals it.
        doc.physical.routes[0].segments[0].waypoints[1].kind = .via
        #expect(!Ratsnest.missingEdges(doc).contains { $0.netLabel == "n1" })
    }
}
