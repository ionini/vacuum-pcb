import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// `stencilScrewPadding` widens screw clearance holes in the silicone cutting
/// template only — independently of `stencilViaPadding`, which sizes the fluid
/// holes. Covers the cut geometry (`PlateBuilder`) and the crowding check that
/// has to follow the wider holes (`DRC.stencilHoleIssues`).
@MainActor
struct StencilScrewPaddingTests {

    // MARK: - Fixtures

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.physical.bottomLayers = 2
        return doc
    }

    private func addScrew(_ doc: inout CircuitDocument, label: String, at p: Point) {
        let screw = Component(kind: .screw, label: label)
        doc.logic.components.append(screw)
        doc.physical.placements.append(
            Placement(componentId: screw.id, position: p, rotation: .r0, layer: .top, depth: 0)
        )
    }

    /// A cross-silicone via: the same net carrying a `.via` waypoint at `p` on
    /// both a T0 and a B0 segment.
    private func addVia(_ doc: inout CircuitDocument, label: String, at p: Point) {
        let net = Net(label: label, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 0),
        ].map {
            Segment(waypoints: [
                Waypoint(position: p, kind: .via),
                Waypoint(position: Point(x: p.x, y: p.y + 5)),
            ], layer: $0)
        }))
    }

    private func stencilIssues(_ doc: CircuitDocument) -> [String] {
        DRC.check(doc).compactMap {
            if case .stencilHole(_, _, let detail) = $0.kind { return detail }
            return nil
        }
    }

    // MARK: - Cut geometry

    @Test("Screw padding widens the stencil hole but not the plate bore")
    func paddingWidensStencilHole() {
        var doc = makeDoc()
        addScrew(&doc, label: "S1", at: Point(x: 40, y: 20))
        // 1.4 mm out from the centre: outside the bare 2.4 mm default bore
        // (r = 1.2), inside a hole padded by 2 mm (r = 2.2).
        let probe = Vector(41.4, 20, 0)

        doc.manufacturing.stencilScrewPadding = 0
        let bare = PlateBuilder.build(doc)
        #expect(bare.stencil.intersects(probe), "unpadded hole should not reach 1.4 mm out")

        doc.manufacturing.stencilScrewPadding = 2.0
        let padded = PlateBuilder.build(doc)
        #expect(!padded.stencil.intersects(probe), "padded hole should swallow the probe point")

        // The plates keep the fastener's own clearance bore either way — the
        // padding is a silicone-relief parameter, not a screw-fit one. Probed
        // at z = 1 mm: inside the top plate (0.05…3.05), below the head
        // countersink, and 1.4 mm out from the 2.4 mm bore → printed material.
        let plateProbe = Vector(41.4, 20, 1.0)
        #expect(bare.topPlate.intersects(plateProbe))
        #expect(padded.topPlate.intersects(plateProbe))
    }

    @Test("Via padding leaves screw holes alone, and vice versa")
    func paddingsAreIndependent() {
        var doc = makeDoc()
        addScrew(&doc, label: "S1", at: Point(x: 40, y: 20))
        let probe = Vector(41.4, 20, 0)

        // A generous via padding must not touch the screw hole.
        doc.manufacturing.stencilViaPadding = 2.0
        doc.manufacturing.stencilScrewPadding = 0
        #expect(PlateBuilder.build(doc).stencil.intersects(probe))

        // …and the screw padding must not need the via padding's help.
        doc.manufacturing.stencilViaPadding = 0
        doc.manufacturing.stencilScrewPadding = 2.0
        #expect(!PlateBuilder.build(doc).stencil.intersects(probe))
    }

    // MARK: - Stencil crowding (DRC)

    @Test("Screw holes merging into each other is not a defect", arguments: [0.0, 2.0, 6.0])
    func screwPairsAreNeverFlagged(padding: Double) {
        var doc = makeDoc()
        doc.manufacturing.stencilScrewPadding = padding
        addVia(&doc, label: "far", at: Point(x: 10, y: 10))   // keeps the fluid set non-empty
        addScrew(&doc, label: "S1", at: Point(x: 40, y: 20))
        addScrew(&doc, label: "S2", at: Point(x: 43, y: 20))  // holes overlap outright at 6 mm
        // Nothing seals or flows between two relief holes, so widening them —
        // which is what the parameter is for — must never raise a warning.
        #expect(stencilIssues(doc).isEmpty)
    }

    @Test("A padded screw eating into a via's sealing land is flagged")
    func paddedScrewNearViaIsFlagged() {
        var doc = makeDoc()
        addVia(&doc, label: "v", at: Point(x: 40, y: 20))
        addScrew(&doc, label: "S1", at: Point(x: 42.6, y: 20))

        doc.manufacturing.stencilScrewPadding = 0
        #expect(stencilIssues(doc).isEmpty)   // 0.75 mm wall — fine unpadded

        doc.manufacturing.stencilScrewPadding = 2.0
        #expect(stencilIssues(doc).contains { $0.contains("via") && $0.contains("screw") })
    }
}
