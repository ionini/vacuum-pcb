import Testing
import Foundation
@testable import Vacuum_PCB

/// The gate dome's defining sphere is centred `dimpleSphereOffset` *into the
/// silicone gap*, so the cap only intrudes `dimpleDiameter/2 −
/// dimpleSphereOffset` past the plate face (1.5 mm at defaults) — see
/// `PlateBuilder.dimpleMesh`. DRC's bore reach must use the same formula: the
/// old `radius + offset` claimed 3.5 mm and produced phantom thin-wall
/// findings against channels buried a full layer below the dome.
@MainActor
struct DRCGateDomeReachTests {

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.physical.topLayers = 2
        return doc
    }

    /// Transistor on the top plate; its gate pin (offset .zero) carves the
    /// dome at the placement position.
    private func placeTransistor(_ doc: inout CircuitDocument, at p: Point) {
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components.append(q)
        doc.physical.placements.append(
            Placement(componentId: q.id, position: p, rotation: .r0, layer: .top, depth: 0))
    }

    /// A bare foreign-net channel (enough for the thin-wall geometry).
    private func addChannel(_ doc: inout CircuitDocument, from a: Point, to b: Point,
                            layer: Layer) {
        let net = Net(label: "n", pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: layer)
        ]))
    }

    private func boreWalls(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .thinWall(let n, _, _, _, _) = $0.kind, n == .bore { return true }
            return false
        }
    }

    @Test("Depth-1 channel below the gate dome's true 1.5 mm reach does not flag")
    func buriedChannelClearsGateDome() {
        var doc = makeDoc()
        placeTransistor(&doc, at: Point(x: 40, y: 20))
        // Passes 1.5 mm from the gate in XY, but its midline sits 3.8 mm past
        // the face — 2.25 mm below the dome band [face, face + 1.5]. The old
        // +offset reach (3.5 mm) left only a 0.25 mm vertical gap and flagged.
        addChannel(&doc, from: Point(x: 30, y: 21.5), to: Point(x: 50, y: 21.5),
                   layer: Layer(plate: .top, depth: 1))
        #expect(boreWalls(doc).isEmpty)
    }

    @Test("Depth-0 channel at the same XY distance still flags")
    func shallowChannelStillFlags() {
        var doc = makeDoc()
        placeTransistor(&doc, at: Point(x: 40, y: 20))
        // Same lateral pass, but at depth 0 the channel midline (1.5 mm past
        // the face) sits inside the dome band — a genuine thin wall.
        addChannel(&doc, from: Point(x: 30, y: 21.5), to: Point(x: 50, y: 21.5),
                   layer: Layer(plate: .top, depth: 0))
        #expect(!boreWalls(doc).isEmpty)
    }
}
