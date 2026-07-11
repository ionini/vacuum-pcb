import Testing
import Foundation
@testable import Vacuum_PCB

/// Testing points bore vertically from a tapped channel out to the plate's
/// outer face. `testPointClearanceIssues` flags when that bore passes within
/// `minWallThickness` of a foreign net's channel or another testing point —
/// a 3D-only clash the flat 2D layer never shows, like a port outlet. The
/// bore is depth-aware: a shallow bore can pass the Z level of a deeper
/// foreign channel on its way out.
@MainActor
struct TestPointClearanceTests {

    private func makeDoc(topLayers: Int = 1) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 30))
        doc.physical.topLayers = topLayers
        return doc
    }

    /// A pin-less net carrying one straight route (enough for the bead's rail
    /// and the clearance geometry; topology checks ignore an empty net).
    @discardableResult
    private func addRoute(
        _ doc: inout CircuitDocument, netLabel: String,
        from a: Point, to b: Point, layer: Layer = .top
    ) -> UUID {
        let net = Net(label: netLabel, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: layer)
        ]))
        return net.id
    }

    private func tpIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter { if case .testPointClearance = $0.kind { return true }; return false }
    }

    @Test("A test point within the min wall of a foreign channel flags")
    func nearForeignChannel() {
        var doc = makeDoc()
        let tap = addRoute(&doc, netLabel: "tap", from: Point(x: 10, y: 15), to: Point(x: 40, y: 15))
        // Foreign channel whose nearest point (25,14) is 1 mm from the bead.
        addRoute(&doc, netLabel: "nc", from: Point(x: 25, y: 14), to: Point(x: 25, y: 5))
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: tap, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        let issues = tpIssues(doc)
        #expect(issues.count == 1)
        #expect(issues.contains {
            if case .testPointClearance(_, "TP1", .channel, "nc", _, _, _) = $0.kind { return true }
            return false
        })
    }

    @Test("A test point on its own net's channel does not flag")
    func ownNetIgnored() {
        var doc = makeDoc()
        let tap = addRoute(&doc, netLabel: "tap", from: Point(x: 10, y: 15), to: Point(x: 40, y: 15))
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: tap, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        #expect(tpIssues(doc).isEmpty)
    }

    @Test("A depth-0 bore flags a laterally-near deeper foreign channel")
    func depthAwareBore() {
        var doc = makeDoc(topLayers: 2)
        let tap = addRoute(&doc, netLabel: "tap", from: Point(x: 10, y: 15), to: Point(x: 40, y: 15))
        // Foreign channel on the DEEPER layer, 1 mm away laterally. A naive
        // same-exact-layer check would miss it; the Z-band bore catches it
        // because the vertical bore passes depth 1 on its way to the surface.
        addRoute(&doc, netLabel: "nc", from: Point(x: 25, y: 14), to: Point(x: 25, y: 5),
                 layer: Layer(plate: .top, depth: 1))
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: tap, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        #expect(tpIssues(doc).contains {
            if case .testPointClearance(_, "TP1", .channel, "nc", _, _, _) = $0.kind { return true }
            return false
        })
    }

    @Test("A far foreign channel does not flag")
    func farChannelClears() {
        var doc = makeDoc()
        let tap = addRoute(&doc, netLabel: "tap", from: Point(x: 10, y: 15), to: Point(x: 40, y: 15))
        // 10 mm away — comfortably outside bore radius + channel radius + wall.
        addRoute(&doc, netLabel: "nc", from: Point(x: 10, y: 5), to: Point(x: 40, y: 5))
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: tap, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        #expect(tpIssues(doc).isEmpty)
    }

    @Test("Two test points closer than the min wall flag as a test-point clash")
    func twoTestPointsClash() {
        var doc = makeDoc()
        let tap = addRoute(&doc, netLabel: "tap", from: Point(x: 10, y: 15), to: Point(x: 40, y: 15))
        // Both ride the same route, 1 mm apart (< 2·boreR + wall).
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: tap, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        doc.physical.testPoints.append(TestPoint(
            name: "TP2", netId: tap, segmentIndex: 0, offset: 16,
            plate: .top, depth: 0, position: Point(x: 26, y: 15)
        ))
        #expect(tpIssues(doc).contains {
            if case .testPointClearance(_, _, .testPoint, _, _, _, _) = $0.kind { return true }
            return false
        })
    }

    // MARK: - Simulation

    /// A testing point is a read-only probe: it must add a probe reading its
    /// net but leave the solve untouched (no boundary / pump / input). This is
    /// what lets it be "inert" — the pressures don't change.
    @MainActor
    @Test("A test point contributes a probe but no boundary/pump/input")
    func inertProbe() {
        var doc = makeDoc()
        let vac = Component(kind: .vacuumSource, label: "VAC1")
        let vent = Component(kind: .atmVent, label: "ATM1")
        doc.logic.components += [vac, vent]
        let nVac = Net(label: "nvac", pins: [PinRef(componentId: vac.id, pinKey: "p")])
        let nVent = Net(label: "nvent", pins: [PinRef(componentId: vent.id, pinKey: "p")])
        doc.logic.nets += [nVac, nVent]
        // A route on nVac gives the test point a rail to ride.
        doc.physical.routes.append(Route(netId: nVac.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 10, y: 15)),
                                Waypoint(position: Point(x: 40, y: 15))], layer: .top)
        ]))

        let before = PneumaticNetwork.build(from: doc.flattenedForSimulation().document)
        doc.physical.testPoints.append(TestPoint(
            name: "TP1", netId: nVac.id, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)
        ))
        let after = PneumaticNetwork.build(from: doc.flattenedForSimulation().document)

        #expect(after.hardBoundaries.count == before.hardBoundaries.count)
        #expect(after.pumps.count == before.pumps.count)
        #expect(after.inputs.count == before.inputs.count)
        #expect(after.probes.count == before.probes.count + 1)
        #expect(after.probes.contains { $0.isTestPoint && $0.label == "TP1" && $0.netId == nVac.id })
    }

    /// A test point registers a probe for the Simulate sidebar, but as a
    /// physical debug tap it must NOT be treated as a functional output by the
    /// validation sweep / robustness gate (else a probe on a marginal internal
    /// node fails Validate).
    @MainActor
    @Test("Test-point probes are excluded from the validation sweep")
    func testPointExcludedFromSweep() {
        var doc = makeDoc()
        let outPort = Component(kind: .port, label: "OUT")   // nil dir → output probe
        doc.logic.components.append(outPort)
        let nOut = Net(label: "nout", pins: [PinRef(componentId: outPort.id, pinKey: "p")])
        doc.logic.nets.append(nOut)
        doc.physical.routes.append(Route(netId: nOut.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 10, y: 15)),
                                Waypoint(position: Point(x: 40, y: 15))], layer: .top)
        ]))
        doc.physical.testPoints.append(TestPoint(
            name: "TP_PROBE", netId: nOut.id, segmentIndex: 0, offset: 15,
            plate: .top, depth: 0, position: Point(x: 25, y: 15)))

        let net = Validators.buildNetwork(doc)
        let sweep = Validators.sweep(network: net, params: .defaults,
                                     maxSteps: 2000, epsilon: 1e-5, maxCombos: 64)
        // Excluded from the validated probe set…
        #expect(sweep.probeLabels.contains("OUT"))
        #expect(!sweep.probeLabels.contains("TP_PROBE"))
        // …but still a probe on the network (the Simulate sidebar reads it).
        #expect(net.probes.contains { $0.isTestPoint && $0.label == "TP_PROBE" })
    }

    // MARK: - Persistence

    @Test("Empty testPoints are omitted from the encoding (v9 docs round-trip)")
    func emptyOmitted() throws {
        let pl = PhysicalLayout(
            placements: [], routes: [],
            boardOutline: Rect(origin: .zero, size: Size(width: 50, height: 30))
        )
        let data = try JSONEncoder().encode(pl)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("testPoints"))
    }

    @Test("A layout with test points round-trips through Codable")
    func roundTrip() throws {
        let tp = TestPoint(
            name: "TP1", netId: UUID(), segmentIndex: 0, offset: 3.5,
            plate: .bottom, depth: 1, position: Point(x: 5, y: 6)
        )
        let pl = PhysicalLayout(
            placements: [], routes: [],
            boardOutline: Rect(origin: .zero, size: Size(width: 50, height: 30)),
            testPoints: [tp]
        )
        let data = try JSONEncoder().encode(pl)
        let back = try JSONDecoder().decode(PhysicalLayout.self, from: data)
        #expect(back.testPoints == [tp])
    }
}
