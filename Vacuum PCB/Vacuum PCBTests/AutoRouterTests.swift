import Testing
import Foundation
@testable import Vacuum_PCB

/// Multi-layer routing: the auto-router must connect a net whose pins live on
/// different channel depths of the same plate, dropping an intra-plate via.
@MainActor
struct AutoRouterTests {

    private func route(_ doc: inout CircuitDocument) {
        for entry in AutoRouter.plan(doc) {
            if let i = doc.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
                doc.physical.routes[i].segments.append(entry.segment)
            } else {
                doc.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
            }
        }
    }

    @Test("Routes a net across two depths of one plate, via an intra-plate via")
    func routesAcrossDepths() {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 40, height: 30))
        doc.physical.topLayers = 2   // depth 0 + depth 1 on the top plate

        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        let r2 = Component(kind: .resistor, label: "R2", resistorSize: .medium)
        doc.logic.components = [r1, r2]
        doc.logic.nets = [Net(label: "n1", pins: [
            PinRef(componentId: r1.id, pinKey: "2"),
            PinRef(componentId: r2.id, pinKey: "1"),
        ])]
        doc.physical.placements = [
            Placement(componentId: r1.id, position: Point(x: 10, y: 15), rotation: .r0, layer: .top, depth: 0),
            Placement(componentId: r2.id, position: Point(x: 28, y: 15), rotation: .r0, layer: .top, depth: 1),
        ]

        route(&doc)

        // Net is fully connected (no disconnected pins / unrouted net).
        let issues = DRC.check(doc)
        let broken = issues.contains {
            switch $0.kind {
            case .disconnectedPin, .noRouteDrawn: return true
            default: return false
            }
        }
        #expect(!broken)

        // The routing actually used both depths — i.e. it dropped a via from
        // depth 0 up to depth 1 rather than failing to bridge them.
        let depths = Set(doc.physical.routes.flatMap { $0.segments.map(\.layer.depth) })
        let usedBothDepths = depths.contains(0) && depths.contains(1)
        #expect(usedBothDepths)
    }
}
