import Testing
import Foundation
@testable import Vacuum_PCB

/// `noRouteDrawn` must stay silent when every placed pin of a net resolves to
/// the same (layer, XY): the drop bores fuse into one void in CSG, so the net
/// is physically connected with no channel — the port-on-socket pattern.
/// Ratsnest already treats those pins as one node; DRC has to agree.
@MainActor
struct DRCCoincidentPinTests {

    private func hasNoRouteDrawn(_ doc: CircuitDocument) -> Bool {
        DRC.check(doc).contains { if case .noRouteDrawn = $0.kind { return true }; return false }
    }

    private func makeDoc(bDepth: Int = 0, bPos: Point = Point(x: 30, y: 15)) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 70, height: 30))
        doc.physical.bottomLayers = 2
        let a = Component(kind: .port, label: "A", portDirection: .input)
        let b = Component(kind: .port, label: "B", portDirection: .output)
        doc.logic.components = [a, b]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: a.id, pinKey: "p"),
            PinRef(componentId: b.id, pinKey: "p"),
        ])]
        doc.physical.placements = [
            Placement(componentId: a.id, position: Point(x: 30, y: 15), rotation: .r0, layer: .bottom, depth: 0),
            Placement(componentId: b.id, position: bPos, rotation: .r0, layer: .bottom, depth: bDepth),
        ]
        return doc
    }

    @Test("Coincident same-layer pins need no route")
    func coincidentPinsSuppressNoRouteDrawn() {
        #expect(!hasNoRouteDrawn(makeDoc()))
    }

    @Test("Same XY on a different depth still needs a route")
    func coincidentXYDifferentLayerStillReports() {
        #expect(hasNoRouteDrawn(makeDoc(bDepth: 1)))
    }

    @Test("Separated pins with no route still report")
    func separatedPinsStillReport() {
        #expect(hasNoRouteDrawn(makeDoc(bPos: Point(x: 50, y: 15))))
    }
}
