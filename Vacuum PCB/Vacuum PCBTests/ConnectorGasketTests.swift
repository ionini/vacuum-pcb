import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// A `.bottomExtend` connector's silicone is cut as its own crushed-gasket
/// piece — a stadium concentric to the pin/screw row (`ConnectorGasket`) with
/// its own hole paddings — by a per-connector stencil, while the board sheet's
/// stencil stays board-only. Covers the pure layout math, the built stencil
/// bodies (`PlateBuilder`), and the per-sheet tear check (`DRC`).
@MainActor
struct ConnectorGasketTests {

    // Defaults: channelDiameter 1.5 + gasket via padding 0.4 → 1.9 mm pin
    // hole; screwThroughDiameter 2.4 + gasket screw padding 1.6 → 4.0 mm
    // screw hole; capsule radius 1.9/2 + 2.0 width = 2.95.
    private let m = ManufacturingConstants.defaults

    // MARK: - Fixtures

    /// 80×40 board with one 2-pin `.bottomExtend` connector on the right
    /// edge (r0 → protrusion along +X). With the default 7 mm outward
    /// extent the row line sits at world x = 83.5; pins land at y = 20 ± 2.5
    /// and the two end-cap screws at y = 20 ± 10.5.
    private func makeDoc(label: String = "J1") -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        addConnector(&doc, label: label, at: Point(x: 80, y: 20), rotation: .r0)
        return doc
    }

    // Qualified: the test target imports Euclid too, whose `Rotation` would
    // otherwise collide with the model's placement rotation.
    private func addConnector(
        _ doc: inout CircuitDocument, label: String, at p: Point,
        rotation: Vacuum_PCB.Rotation
    ) {
        let connector = Component(
            kind: .connector, label: label,
            connectorPinCount: 2, connectorRole: .bottomExtend
        )
        doc.logic.components.append(connector)
        doc.physical.placements.append(
            Placement(componentId: connector.id, position: p, rotation: rotation, layer: .bottom)
        )
    }

    // MARK: - Pure layout math

    @Test("Capsule bounds every hole centre by the capsule radius")
    func capsuleBoundsRow() {
        let pins = [Point(x: 0, y: -2.5), Point(x: 0, y: 2.5)]
        let screws = [Point(x: 0, y: -10.5), Point(x: 0, y: 10.5)]
        let g = ConnectorGasket.layout(pinCentres: pins, screwCentres: screws, m: m)!
        let r = ConnectorGasket.capsuleRadius(m)
        #expect(abs(r - 2.95) < 1e-9)
        #expect(abs(g.cornerRadius - r) < 1e-9)
        #expect(abs(g.outline.origin.x - (-r)) < 1e-9)
        #expect(abs(g.outline.origin.y - (-10.5 - r)) < 1e-9)
        #expect(abs(g.outline.size.width - 2 * r) < 1e-9)
        #expect(abs(g.outline.size.height - (21 + 2 * r)) < 1e-9)
    }

    @Test("Pin and screw holes take the gasket paddings, not the sheet's")
    func holeDiameters() {
        var mfg = m
        mfg.stencilViaPadding = 2.0      // board-sheet paddings must not bleed in
        mfg.stencilScrewPadding = 6.0
        let g = ConnectorGasket.layout(
            pinCentres: [Point(x: 0, y: 0)], screwCentres: [Point(x: 0, y: 10.5)], m: mfg
        )!
        #expect(abs(g.pinHoles[0].diameter - (1.5 + 0.4)) < 1e-9)
        #expect(abs(g.screwHoles[0].diameter - (2.4 + 1.6)) < 1e-9)
        // Rotated rows lay out along X the same way (world axes, quarter turns).
        let h = ConnectorGasket.layout(
            pinCentres: [Point(x: 1, y: 0), Point(x: 6, y: 0)], screwCentres: [], m: m
        )!
        #expect(abs(h.outline.size.width - (5 + 2 * h.cornerRadius)) < 1e-9)
        #expect(abs(h.outline.size.height - 2 * h.cornerRadius) < 1e-9)
    }

    @Test("No centres → no gasket")
    func emptyRow() {
        #expect(ConnectorGasket.layout(pinCentres: [], screwCentres: [], m: m) == nil)
    }

    // MARK: - Built stencils

    @Test("Connector holes and protrusion leave the board sheet's stencil")
    func boardStencilIsBoardOnly() {
        let out = PlateBuilder.build(makeDoc())
        // Inside the board rectangle the sheet is still there…
        #expect(out.stencil.intersects(Vector(79.5, 20, 0)))
        // …but it no longer extends into the protrusion (the old behaviour
        // carried a protrusion-shaped extension past the board edge).
        #expect(!out.stencil.intersects(Vector(80.2, 20, 0)))
        #expect(!out.stencil.intersects(Vector(83.5, 20, 0)))
    }

    @Test("Gasket stencil: stadium band, pin holes, screw clearance holes")
    func gasketStencilGeometry() {
        let out = PlateBuilder.build(makeDoc())
        #expect(out.connectorStencils.count == 1)
        #expect(out.connectorStencils[0].name == "J1")
        let gasket = out.connectorStencils[0].mesh

        // Solid on the band between the two pins…
        #expect(gasket.intersects(Vector(83.5, 20, 0)))
        // …cut open at a pin (1.9 mm hole) and at an end-cap screw (4.0 mm)…
        #expect(!gasket.intersects(Vector(83.5, 22.5, 0)))
        #expect(!gasket.intersects(Vector(83.5, 30.5, 0)))
        // …and absent outside the capsule, even where the protrusion (and the
        // old stencil extension) still has plate under it.
        #expect(!gasket.intersects(Vector(81.0, 33.0, 0)))
        #expect(!out.stencil.intersects(Vector(81.0, 33.0, 0)))
    }

    @Test("Gasket names deduplicate repeated labels in placement order")
    func gasketNamesDeduplicate() {
        var doc = makeDoc(label: "CN")
        addConnector(&doc, label: "CN", at: Point(x: 0, y: 20), rotation: .r180)
        let out = PlateBuilder.build(doc)
        #expect(out.connectorStencils.map(\.name) == ["CN", "CN_2"])
    }

    @Test("Debug-ports and zero stencil thickness produce no gasket stencils")
    func gasketSkips() {
        var doc = makeDoc()
        doc.logic.components[0].connectorDebugPorts = true
        #expect(PlateBuilder.build(doc).connectorStencils.isEmpty)

        var thin = makeDoc()
        thin.manufacturing.stencilThickness = 0
        #expect(PlateBuilder.build(thin).connectorStencils.isEmpty)
    }

    // MARK: - Per-sheet tear check (DRC)

    private func stencilIssues(_ doc: CircuitDocument) -> [String] {
        DRC.check(doc).compactMap {
            if case .stencilHole(_, _, let detail) = $0.kind { return detail }
            return nil
        }
    }

    /// A cross-silicone via (same net, `.via` waypoint on a T0 and a B0
    /// segment) — the board sheet's fluid hole.
    private func addVia(_ doc: inout CircuitDocument, label: String, at p: Point) {
        let net = Net(label: label, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 0),
        ].map {
            Segment(waypoints: [
                Waypoint(position: p, kind: .via),
                Waypoint(position: Point(x: p.x, y: p.y - 5)),
            ], layer: $0)
        }))
    }

    @Test("A board via near a connector end-cap no longer flags — separate sheets")
    func boardViaAndGasketHolesDontPair() {
        var doc = makeDoc()
        // Board via 4.5 mm from the lower end-cap screw (83.5, 9.5). Under the
        // one-sheet check with this padding the screw hole (r = 4.2) ate the
        // via's land outright; as separate cut pieces there is nothing to tear.
        doc.manufacturing.stencilScrewPadding = 6.0
        addVia(&doc, label: "v", at: Point(x: 79, y: 10))
        #expect(stencilIssues(doc).isEmpty)
    }

    @Test("Within a gasket, crowding is judged at the gasket diameters")
    func gasketCrowdingUsesGasketPaddings() {
        // Pin ↔ end-cap distance is 8 mm. At threshold 3 mm the pair only
        // crowds once the gasket screw padding is opened right up:
        // 8 − 1.9/2 − (2.4+6)/2 = 2.85 < 3.
        var doc = makeDoc()
        doc.manufacturing.minWallThickness = 3.0
        doc.manufacturing.connectorGasketScrewPadding = 6.0
        #expect(stencilIssues(doc).contains { $0.contains("connector pin") && $0.contains("end-cap screw") })

        // The board sheet's screw padding must not leak into the gasket check:
        // wide-open there, closed on the gasket → 8 − 0.95 − 1.2 = 5.85, fine.
        doc.manufacturing.connectorGasketScrewPadding = 0
        doc.manufacturing.stencilScrewPadding = 6.0
        #expect(stencilIssues(doc).isEmpty)
    }
}
