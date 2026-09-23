import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// Flared resistor mouths (`PlateBuilder.resistorEndFlareMeshes`): under
/// smooth resistors an L's bore opens to the transport channel diameter at
/// each pin, so the joint prints the same whether the route arrives along
/// the resistor axis or from the side. Probed on the real plate mesh.
@MainActor
struct ResistorFlareTests {

    private let top0 = Layer(plate: .top, depth: 0)

    /// One resistor at (30, 20), axis along X: pin 1 at (24, 20) fed straight
    /// in along the axis from a vent at (12, 20); pin 2 at (36, 20) fed from
    /// the side by a route running up +Y from a vent at (36, 8).
    private func doc(size: ResistorSize) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 60, height: 40))
        doc.skipEdgeWallDRC = true
        doc.manufacturing.smoothResistors = true
        let r = Component(kind: .resistor, label: "R1", resistorSize: size)
        let a = Component(kind: .atmVent, label: "A")
        let b = Component(kind: .atmVent, label: "B")
        doc.logic.components = [r, a, b]
        let rp = Placement(componentId: r.id, position: Point(x: 30, y: 20), rotation: .r0, layer: .top, depth: 0)
        doc.physical.placements = [
            rp,
            // Vent bores run to the board edge in the placement's direction:
            // A exits −X (away from the resistor), B exits +X.
            Placement(componentId: a.id, position: Point(x: 12, y: 20), rotation: .r180, layer: .top, depth: 0),
            Placement(componentId: b.id, position: Point(x: 36, y: 8), rotation: .r0, layer: .top, depth: 0),
        ]
        let fp = r.footprint(doc.manufacturing)
        let p1 = rp.worldPosition(of: fp.pin("1")!)
        let p2 = rp.worldPosition(of: fp.pin("2")!)
        let nA = Net(label: "nA", pins: [PinRef(componentId: a.id, pinKey: "p"), PinRef(componentId: r.id, pinKey: "1")])
        let nB = Net(label: "nB", pins: [PinRef(componentId: b.id, pinKey: "p"), PinRef(componentId: r.id, pinKey: "2")])
        doc.logic.nets = [nA, nB]
        doc.physical.routes = [
            Route(netId: nA.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 12, y: 20)), Waypoint(position: p1)], layer: top0)]),
            Route(netId: nB.id, segments: [Segment(waypoints: [
                Waypoint(position: Point(x: 36, y: 8)), Waypoint(position: p2)], layer: top0)]),
        ]
        return doc
    }

    /// Probe points 0.75 mm inside each pin along the resistor axis, offset
    /// 0.36 mm sideways (+Y): outside the 0.6 mm resistor bore (r 0.3),
    /// outside the route's 1.5 mm end sphere (lateral reach 0.09 mm there,
    /// 0.83 mm from the pin centre against a 0.755 mm sphere / 0.75 mm floor
    /// disc), inside the flare cone (r ≈ 0.39 mm at that depth). `wall` sits
    /// 0.55 mm out — beyond the cone, in printed material.
    private struct Probes {
        let inFlare1, wall1, inFlare2, wall2: Vector
        init(m: ManufacturingConstants) {
            let z = m.midZ(for: Layer(plate: .top, depth: 0))
            inFlare1 = Vector(24.75, 20.36, z)   // straight-in pin
            wall1    = Vector(24.75, 20.55, z)
            inFlare2 = Vector(35.25, 20.36, z)   // side-entry pin
            wall2    = Vector(35.25, 20.55, z)
        }
    }

    /// The export's own judgement (`Validators.mesh`): the raw CSG output has
    /// hairline T-junction cracks that `makeWatertight` stitches; what must not
    /// remain afterwards are the duplicate internal faces coincident caps leave.
    private func printsClean(_ mesh: Mesh) -> Bool {
        let s = mesh.makeWatertight()
        return s.isWatertight && s.signedVolume > 0
    }

    @Test("Smooth L: both mouths are flared to the channel bore, straight-in and side-entry alike")
    func largeIsFlaredAtBothEnds() {
        let d = doc(size: .large)
        #expect(d.manufacturing.resistorChannelDiameter == 0.6)
        #expect(d.manufacturing.channelDiameter == 1.5)
        let out = PlateBuilder.build(d)
        let p = Probes(m: d.manufacturing)

        // Carved: the plate has no material where only the flare reaches…
        #expect(!out.topPlate.intersects(p.inFlare1), "straight-in mouth not flared")
        #expect(!out.topPlate.intersects(p.inFlare2), "side-entry mouth not flared")
        #expect(out.topFeatures.intersects(p.inFlare1))
        #expect(out.topFeatures.intersects(p.inFlare2))
        // …and still has it just beyond the cone.
        #expect(out.topPlate.intersects(p.wall1))
        #expect(out.topPlate.intersects(p.wall2))

        #expect(printsClean(out.topPlate))
    }

    @Test("Smooth M keeps plain bore mouths")
    func mediumIsNotFlared() {
        let d = doc(size: .medium)
        let out = PlateBuilder.build(d)
        let p = Probes(m: d.manufacturing)
        // The lead is a bare 0.6 mm bore: material at the probe points.
        #expect(out.topPlate.intersects(p.inFlare1))
        #expect(out.topPlate.intersects(p.inFlare2))
        #expect(printsClean(out.topPlate))
    }

    @Test("Legacy zigzag L is never flared")
    func legacyIsNotFlared() {
        var d = doc(size: .large)
        d.manufacturing.smoothResistors = false
        let m = d.manufacturing
        #expect(PlateBuilder.resistorEndFlareMeshes(
            center: Point(x: 30, y: 20), rotation: .r0, size: .large,
            m: m, midZ: m.midZ(for: top0)).isEmpty)
        let out = PlateBuilder.build(d)
        // The zigzag's first jump rises on +Y right at the lead's end, so
        // probe the −Y side of pin 1's lead: 0.44 mm from the jump and the
        // lead's end sphere, 0.36 mm off the 0.3 mm lead bore — material.
        let z = m.midZ(for: top0)
        #expect(out.topPlate.intersects(Vector(24.75, 19.64, z)))
    }

    @Test("Flare cones follow the placement rotation and open at the pin")
    func conesFollowRotation() {
        var m = ManufacturingConstants.defaults
        m.smoothResistors = true
        let z = m.midZ(for: top0)
        // Rotated 90°: the resistor axis is Y, pins at (0, ±6).
        let cones = PlateBuilder.resistorEndFlareMeshes(
            center: .zero, rotation: .r90, size: .large, m: m, midZ: z)
        #expect(cones.count == 2)
        let ys = cones.map { ($0.bounds.min.y + $0.bounds.max.y) / 2 }.sorted()
        #expect(ys.count == 2 && ys[0] < -5 && ys[1] > 5)
        for cone in cones {
            let b = cone.bounds
            #expect(abs(b.size.x - m.channelDiameter) < 0.02)   // mouth = channel bore
            #expect(abs(b.size.y - (ResistorGeometry.flareLength(m: m) + 0.02)) < 1e-6)
            let towardPin: Double = ((b.min.y + b.max.y) / 2 < 0) ? -1 : 1
            // Wide at the pin end, narrow at the throat.
            #expect(cone.intersects(Vector(0.5, towardPin * 5.9, z)))
            #expect(!cone.intersects(Vector(0.5, towardPin * 5.1, z)))
        }

        // The flare length parameter sets the cone's length (and, via the
        // lead, where the meander starts — see ResistorGeometryTests).
        var long = m
        long.resistorFlareLength = 2.0
        let longCones = PlateBuilder.resistorEndFlareMeshes(
            center: .zero, rotation: .r90, size: .large, m: long, midZ: z)
        #expect(longCones.count == 2)
        for cone in longCones {
            #expect(abs(cone.bounds.size.y - 2.02) < 1e-6)
            #expect(abs(cone.bounds.size.x - m.channelDiameter) < 0.02)
        }
        // 0 = off.
        var off = m
        off.resistorFlareLength = 0
        #expect(PlateBuilder.resistorEndFlareMeshes(
            center: .zero, rotation: .r0, size: .large, m: off, midZ: z).isEmpty)

        // No flare for M, or when the transport bore is not wider than the
        // resistor bore.
        #expect(PlateBuilder.resistorEndFlareMeshes(
            center: .zero, rotation: .r0, size: .medium, m: m, midZ: z).isEmpty)
        var narrow = m
        narrow.channelDiameter = narrow.resistorChannelDiameter
        #expect(PlateBuilder.resistorEndFlareMeshes(
            center: .zero, rotation: .r0, size: .large, m: narrow, midZ: z).isEmpty)
    }
}
