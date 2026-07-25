import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// The 3D Simulate view's render model must agree with the 2D physical
/// canvas about *what* is shown and *which* solver values tint it: channel
/// spans split into per-layer runs (with vertical via tubes at layer
/// changes), tint sources interpolate span end pressures at the right arc
/// position, and component cavities read the same nets as the 2D bodies.
@MainActor
struct Simulate3DGeometryTests {

    /// Two resistors on B0 wired through a B1 detour with paired vias —
    /// the RatsnestTests topology, which exercises runs on two layers plus
    /// two layer changes inside one net.
    private func makeViaDoc() -> CircuitDocument {
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

        let pA = p1.worldPosition(of: r1.footprint(doc.manufacturing).pin("2")!)
        let pB = p2.worldPosition(of: r2.footprint(doc.manufacturing).pin("1")!)

        let b0 = Layer(plate: .bottom, depth: 0)
        let b1 = Layer(plate: .bottom, depth: 1)
        let v1 = Point(x: 25, y: 15)
        let v2 = Point(x: 35, y: 15)

        doc.physical.routes = [Route(netId: doc.logic.nets[0].id, segments: [
            Segment(waypoints: [Waypoint(position: pA),
                                Waypoint(position: v1, kind: .via)], layer: b0),
            Segment(waypoints: [Waypoint(position: v1, kind: .via),
                                Waypoint(position: v2, kind: .via)], layer: b1),
            Segment(waypoints: [Waypoint(position: v2, kind: .via),
                                Waypoint(position: pB)], layer: b0),
        ])]
        return doc
    }

    private func build(_ doc: CircuitDocument) -> Simulate3DGeometry {
        let flat = doc.flattenedForSimulation()
        let network = Validators.buildNetwork(doc)
        return Simulate3DGeometry.build(flat: flat.document, network: network)
    }

    // MARK: - Pure geometry helpers

    @Test("FlowPath arc-length table and point(at:) interpolation")
    func flowPathInterpolation() {
        let path = Simulate3DGeometry.FlowPath(
            source: .resistor(UUID()),
            points: [Vector(0, 0, 0), Vector(10, 0, 0), Vector(10, 5, 0)],
            layers: []
        )
        #expect(abs(path.totalLength - 15) < 1e-9)
        let mid = path.point(at: 12.5)
        #expect(abs(mid.x - 10) < 1e-9)
        #expect(abs(mid.y - 2.5) < 1e-9)
        // Clamped at both ends.
        #expect(path.point(at: -3) == Vector(0, 0, 0))
        #expect(path.point(at: 99) == Vector(10, 5, 0))
    }

    @Test("Tube and via primitives land at their layer Z")
    func primitiveBounds() {
        let tube = Simulate3DGeometry.tubeMesh(
            waypoints: [Point(x: 0, y: 0), Point(x: 10, y: 0)], radius: 1, midZ: 3)
        #expect(!tube.polygons.isEmpty)
        #expect(abs((tube.bounds.min.z + tube.bounds.max.z) / 2 - 3) < 0.01)

        let via = Simulate3DGeometry.verticalTube(at: Point(x: 1, y: 2), radius: 1, z1: -2, z2: 4)
        #expect(!via.polygons.isEmpty)
        #expect(abs(via.bounds.min.z - (-2)) < 0.01)
        #expect(abs(via.bounds.max.z - 4) < 0.01)
    }

    // MARK: - Routed net decomposition

    @Test("Span runs split per layer, with vertical tubes at the via bores")
    func spanRunsAndVias() throws {
        let doc = makeViaDoc()
        let g = build(doc)
        let m = doc.manufacturing
        let b0 = Layer(plate: .bottom, depth: 0)
        let b1 = Layer(plate: .bottom, depth: 1)

        // Channel units on both routed layers.
        let channelUnits = g.units.filter {
            if case .spanInterpolated = $0.source { return true } else { return false }
        }
        #expect(channelUnits.contains { $0.layers == [b0] })
        #expect(channelUnits.contains { $0.layers == [b1] })

        // The layer changes appear as two-layer via units spanning the two
        // channel midlines.
        let viaUnits = channelUnits.filter { $0.layers.count == 2 }
        #expect(viaUnits.count == 2)
        for via in viaUnits {
            #expect(Set(via.layers) == Set([b0, b1]))
            let lo = min(m.midZ(for: b0), m.midZ(for: b1))
            let hi = max(m.midZ(for: b0), m.midZ(for: b1))
            #expect(abs(via.mesh.bounds.min.z - lo) < 0.01)
            #expect(abs(via.mesh.bounds.max.z - hi) < 0.01)
        }

        // Every span tint source references the routed net's solver nodes.
        let network = Validators.buildNetwork(doc)
        let netId = try #require(network.channelGraph.hubBySubNode.values.first
                                 ?? doc.logic.nets.first?.id)
        for unit in channelUnits {
            guard case .spanInterpolated(let n1, let n2, let t) = unit.source else { continue }
            let hub1 = network.channelGraph.hubBySubNode[n1] ?? n1
            let hub2 = network.channelGraph.hubBySubNode[n2] ?? n2
            #expect(hub1 == netId)
            #expect(hub2 == netId)
            #expect(t >= 0 && t <= 1)
        }

        // Dot paths: the via bores march too — a two-point vertical path.
        let verticalPaths = g.flowPaths.filter { path in
            guard case .span = path.source, path.points.count == 2 else { return false }
            let a = path.points[0], b = path.points[1]
            return abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 && abs(a.z - b.z) > 0.1
        }
        #expect(verticalPaths.count == 2)
        for path in verticalPaths {
            #expect(abs(path.totalLength - abs(path.points[0].z - path.points[1].z)) < 1e-9)
        }

        // Resistor serpentines: one tinted unit and one dot path per body,
        // each unit tagged with its component so a supply-budget row click
        // can glow it.
        let resistorPaths = g.flowPaths.filter {
            if case .resistor = $0.source { return true } else { return false }
        }
        #expect(resistorPaths.count == 2)
        let meanUnits = g.units.filter {
            if case .mean = $0.source { return true } else { return false }
        }
        #expect(meanUnits.count == 2)
        #expect(meanUnits.allSatisfy { $0.component != nil })
        // Routed channel geometry carries no component tag.
        #expect(channelUnits.allSatisfy { $0.component == nil })
    }

    @Test("Ghost slabs bracket the plates and the silicone sheet")
    func bodySlabs() {
        let doc = makeViaDoc()
        let g = build(doc)
        let m = doc.manufacturing
        let sil = m.siliconeThickness / 2

        #expect(abs(g.topSlab.bounds.min.z - sil) < 1e-6)
        #expect(abs(g.topSlab.bounds.max.z - (sil + m.plateThickness(forLayerCount: 1))) < 1e-6)
        // Two bottom layers → thicker bottom plate.
        #expect(abs(g.bottomSlab.bounds.max.z - (-sil)) < 1e-6)
        #expect(abs(g.bottomSlab.bounds.min.z - (-sil - m.plateThickness(forLayerCount: 2))) < 1e-6)
        #expect(abs(g.sheetSlab.bounds.min.z - (-sil)) < 1e-6)
        #expect(abs(g.sheetSlab.bounds.max.z - sil) < 1e-6)
    }

    @Test("Test points bore from their channel to the outer face, tinted by raw net id")
    func testPointUnits() throws {
        var doc = makeViaDoc()
        let netId = doc.logic.nets[0].id
        doc.physical.testPoints = [TestPoint(
            name: "TP1", netId: netId, segmentIndex: 0, offset: 5,
            plate: .bottom, depth: 0, position: Point(x: 13, y: 15))]
        let g = build(doc)

        let tpUnits = g.units.filter {
            if case .rawNet(let id) = $0.source { return id == netId } else { return false }
        }
        let unit = try #require(tpUnits.first)
        #expect(!unit.mesh.isEmpty)
        #expect(unit.layers == [Layer(plate: .bottom, depth: 0)])
        // Bores out of the *bottom* outer face: below the channel midline.
        let m = doc.manufacturing
        let outer = -m.siliconeThickness / 2 - m.plateThickness(forLayerCount: 2)
        #expect(unit.mesh.bounds.min.z < outer + 0.2)
    }

    // MARK: - Component cavities

    @Test("Transistor dome reads the gate net; each pad lobe reads its own pin net")
    func transistorUnits() throws {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 40, height: 30))
        let q = Component(kind: .transistor, label: "Q1")
        let port = Component(kind: .port, label: "IN")
        doc.logic.components = [q, port]
        let gateNet = Net(label: "g", pins: [PinRef(componentId: q.id, pinKey: "gate"),
                                             PinRef(componentId: port.id, pinKey: "p")])
        let aNet = Net(label: "a", pins: [PinRef(componentId: q.id, pinKey: "a")])
        let bNet = Net(label: "b", pins: [PinRef(componentId: q.id, pinKey: "b")])
        doc.logic.nets = [gateNet, aNet, bNet]
        doc.physical.placements = [
            Placement(componentId: q.id, position: Point(x: 20, y: 15), rotation: .r90, layer: .top, depth: 0),
            Placement(componentId: port.id, position: Point(x: 40, y: 15), rotation: .r0, layer: .top, depth: 0),
        ]
        let g = build(doc)

        // Dome: gate-net tint + openness hook + budget-highlight tag, on the
        // placement plate.
        let dome = try #require(g.units.first { $0.opennessComponent == q.id })
        if case .net(let id) = dome.source {
            #expect(id == gateNet.id)
        } else {
            Issue.record("dome tint source should be the gate net")
        }
        #expect(dome.layers == [Layer(plate: .top, depth: 0)])
        #expect(dome.component == q.id)

        // Pads: one unit per pin net, on the opposite plate, tagged with the
        // transistor for the budget highlight.
        let padLayer = Layer(plate: .bottom, depth: 0)
        let padUnits = g.units.filter { $0.layers == [padLayer] }
        let padNets: Set<UUID> = Set(padUnits.compactMap { unit -> UUID? in
            guard case .net(let id) = unit.source else { return nil }
            return id
        })
        #expect(padNets == Set([aNet.id, bNet.id]))
        #expect(padUnits.allSatisfy { $0.component == q.id })

        // Source→drain dot bridge at the pads' membrane surface.
        let bridge = try #require(g.flowPaths.first {
            if case .transistor(let id) = $0.source { return id == q.id } else { return false }
        })
        #expect(bridge.points.count == 2)
        let zPad = -doc.manufacturing.siliconeThickness / 2
        #expect(abs(bridge.points[0].z - zPad) < 1e-6)
        #expect(abs(bridge.points[1].z - zPad) < 1e-6)

        // The edge port bores in, tinted by its net (= the gate net here).
        let portUnits = g.units.filter { unit in
            guard case .net(let id) = unit.source, id == gateNet.id else { return false }
            return unit.opennessComponent == nil
        }
        #expect(portUnits.contains { !$0.mesh.isEmpty })
    }
}
