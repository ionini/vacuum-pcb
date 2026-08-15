import Testing
import Foundation
import Euclid
@testable import Vacuum_PCB

/// A via that spans the two plates crosses the silicone sheet no matter which
/// depth it lands on in each plate — `crossSiliconeViaPositions` must report
/// it and the stencil must cut its hole. Regression coverage for the T0↔B1
/// via whose silicone hole the depth-0-only pairing left uncut ("4bit
/// register with bus 3", vias at (46,24)/(46,58)): the plates got the bore,
/// the sheet stayed solid, and the net was blocked at the sheet.
@MainActor
struct StencilCrossPlateViaTests {

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.physical.topLayers = 2
        doc.physical.bottomLayers = 2
        return doc
    }

    /// One net carrying a `.via` waypoint at `p` on each of the given layers.
    private func addVia(_ doc: inout CircuitDocument, label: String, at p: Point, layers: [Layer]) {
        let net = Net(label: label, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: layers.map {
            Segment(waypoints: [
                Waypoint(position: p, kind: .via),
                Waypoint(position: Point(x: p.x, y: p.y + 5)),
            ], layer: $0)
        }))
    }

    @Test("Cross-plate vias register at any depth; same-plate vias never do")
    func crossPlatePairingIgnoresDepth() {
        var doc = makeDoc()
        addVia(&doc, label: "t0b0", at: Point(x: 10, y: 10),
               layers: [Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 0)])
        addVia(&doc, label: "t0b1", at: Point(x: 30, y: 10),
               layers: [Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 1)])
        addVia(&doc, label: "t1b1", at: Point(x: 50, y: 10),
               layers: [Layer(plate: .top, depth: 1), Layer(plate: .bottom, depth: 1)])
        addVia(&doc, label: "samePlate", at: Point(x: 70, y: 10),
               layers: [Layer(plate: .top, depth: 0), Layer(plate: .top, depth: 1)])

        let positions = doc.physical.crossSiliconeViaPositions()
        #expect(positions.count == 3)
        #expect(positions.contains { abs($0.x - 10) < 0.05 && abs($0.y - 10) < 0.05 })
        #expect(positions.contains { abs($0.x - 30) < 0.05 && abs($0.y - 10) < 0.05 })
        #expect(positions.contains { abs($0.x - 50) < 0.05 && abs($0.y - 10) < 0.05 })
        // The same-plate via never pierces the sheet.
        #expect(!positions.contains { abs($0.x - 70) < 0.05 })
    }

    @Test("The stencil cuts a hole for a T0↔B1 via, and none for a same-plate one")
    func stencilCutsCrossPlateHole() {
        var doc = makeDoc()
        addVia(&doc, label: "t0b1", at: Point(x: 30, y: 10),
               layers: [Layer(plate: .top, depth: 0), Layer(plate: .bottom, depth: 1)])
        addVia(&doc, label: "samePlate", at: Point(x: 50, y: 10),
               layers: [Layer(plate: .top, depth: 0), Layer(plate: .top, depth: 1)])

        let stencil = PlateBuilder.build(doc).stencil
        #expect(!stencil.intersects(Vector(30, 10, 0)), "T0↔B1 via must get a sheet hole")
        #expect(stencil.intersects(Vector(50, 10, 0)), "same-plate via must not pierce the sheet")
    }
}
