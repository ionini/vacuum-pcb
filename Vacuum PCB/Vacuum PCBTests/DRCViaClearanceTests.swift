import Testing
import Foundation
@testable import Vacuum_PCB

/// `viaClearanceIssues` (via↔via `viaSpacing`, via↔pad `viaPad`) must be
/// depth-aware: a pair only conflicts when the bores' Z bands genuinely
/// overlap. An intra-plate (B0↔B1) via passes beside a shallow depth-0 drop
/// bore — their bands merely touch at the depth-0 midline, where each opens
/// into its own channel — while a cross-silicone via shares the face→midline
/// band with the pad and must still report.
@MainActor
struct DRCViaClearanceTests {

    /// Lateral centre-to-centre distance leaving a wall of half the minimum —
    /// close enough to flag whenever the Z bands overlap.
    private func tooClose(_ m: ManufacturingConstants) -> Double {
        m.channelDiameter + m.minWallThickness / 2
    }

    private func hasViaPad(_ doc: CircuitDocument) -> Bool {
        DRC.check(doc).contains { if case .viaPad = $0.kind { return true }; return false }
    }

    private func hasViaSpacing(_ doc: CircuitDocument) -> Bool {
        DRC.check(doc).contains { if case .viaSpacing = $0.kind { return true }; return false }
    }

    /// A net + route whose segments on `layers` all carry a `.via` waypoint
    /// at `p` — the twin markers a real via is made of.
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

    /// Transistor placed on top → its "a"/"b" pads drop on the BOTTOM plate
    /// (`relativeLayer: .opposite`), the gate dome stays on top. Returns pad
    /// "a"'s world position.
    private func placeTransistor(_ doc: inout CircuitDocument, at p: Point) -> Point {
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components.append(q)
        let pl = Placement(componentId: q.id, position: p, rotation: .r0, layer: .top, depth: 0)
        doc.physical.placements.append(pl)
        let pin = q.footprint(doc.manufacturing).pin("a")!
        return pl.worldPosition(of: pin)
    }

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        doc.physical.bottomLayers = 2
        return doc
    }

    @Test("Intra-plate via beside a shallow foreign pad does not flag")
    func intraPlateViaNearPadIsFine() {
        var doc = makeDoc()
        let pad = placeTransistor(&doc, at: Point(x: 40, y: 20))
        let d = tooClose(doc.manufacturing)
        addVia(&doc, label: "v", at: Point(x: pad.x - d, y: pad.y),
               layers: [Layer(plate: .bottom, depth: 0), Layer(plate: .bottom, depth: 1)])
        #expect(!hasViaPad(doc))
    }

    @Test("Cross-silicone via beside the same pad still flags")
    func crossSiliconeViaNearPadReported() {
        var doc = makeDoc()
        let pad = placeTransistor(&doc, at: Point(x: 40, y: 20))
        let d = tooClose(doc.manufacturing)
        addVia(&doc, label: "v", at: Point(x: pad.x - d, y: pad.y),
               layers: [Layer(plate: .bottom, depth: 0), Layer(plate: .top, depth: 0)])
        #expect(hasViaPad(doc))
    }

    @Test("Foreign vias whose Z bands only touch at a midline do not flag")
    func bandTouchingViasAreFine() {
        var doc = makeDoc()
        let d = tooClose(doc.manufacturing)
        addVia(&doc, label: "v1", at: Point(x: 40, y: 20),
               layers: [Layer(plate: .bottom, depth: 0), Layer(plate: .bottom, depth: 1)])
        addVia(&doc, label: "v2", at: Point(x: 40 + d, y: 20),
               layers: [Layer(plate: .bottom, depth: 0), Layer(plate: .top, depth: 0)])
        #expect(!hasViaSpacing(doc))
    }

    @Test("Foreign vias sharing a Z band flag as before")
    func overlappingViasReported() {
        var doc = makeDoc()
        let d = tooClose(doc.manufacturing)
        for (i, x) in [40.0, 40.0 + d].enumerated() {
            addVia(&doc, label: "v\(i)", at: Point(x: x, y: 20),
                   layers: [Layer(plate: .bottom, depth: 0), Layer(plate: .bottom, depth: 1)])
        }
        #expect(hasViaSpacing(doc))
    }
}
