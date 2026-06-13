import Testing
import Foundation
@testable import Vacuum_PCB

/// `portBoreClearanceIssues` catches collisions that exist only once a port is
/// extended to the board edge in the 3D / mold geometry: the outlet bore runs
/// from the port placement straight out to the nearest edge, and on the way it
/// can cross a foreign net's channel or another port's outlet — neither of
/// which shows up on the flat 2D physical layer, so `channelClearance` misses
/// it. Same-net pairs are left alone (the port's own route attaches at the pin).
@MainActor
struct DRCPortBoreClearanceTests {

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 30))
        return doc
    }

    /// A port on its own single-pin net, placed and rotated so its edge bore
    /// projects toward the matching board edge.
    @discardableResult
    private func addPort(
        _ doc: inout CircuitDocument, label: String, netLabel: String,
        at p: Point, rotation: Rotation, layer: Plate = .top
    ) -> (port: UUID, net: UUID) {
        let port = Component(kind: .port, label: label)
        doc.logic.components.append(port)
        let net = Net(label: netLabel, pins: [PinRef(componentId: port.id, pinKey: "p")])
        doc.logic.nets.append(net)
        doc.physical.placements.append(
            Placement(componentId: port.id, position: p, rotation: rotation, layer: layer, depth: 0)
        )
        return (port.id, net.id)
    }

    /// A bare two-waypoint channel on its own pin-less net (enough for the
    /// clearance geometry; topology checks ignore an empty net).
    @discardableResult
    private func addChannel(
        _ doc: inout CircuitDocument, netLabel: String, from a: Point, to b: Point,
        layer: Layer? = nil
    ) -> UUID {
        let net = Net(label: netLabel, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(
                waypoints: [Waypoint(position: a), Waypoint(position: b)],
                layer: layer ?? Layer(plate: .top, depth: 0)
            )
        ]))
        return net.id
    }

    private func portBoreIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter { if case .portBoreClearance = $0.kind { return true }; return false }
    }

    @Test("Outlet sailing over a foreign channel flags as a channel clash")
    func outletCrossesForeignChannel() {
        var doc = makeDoc()
        // P1 faces −Y → outlet runs straight down x=25, y: 15 → 0.
        addPort(&doc, label: "P1", netLabel: "np", at: Point(x: 25, y: 15), rotation: .r270)
        // Foreign channel crossing the outlet path at (25, 5).
        addChannel(&doc, netLabel: "nc", from: Point(x: 10, y: 5), to: Point(x: 40, y: 5))

        let issues = portBoreIssues(doc)
        #expect(issues.count == 1)
        #expect(issues.contains {
            if case .portBoreClearance(_, "P1", .channel, _, _, "nc", _, _, _) = $0.kind { return true }
            return false
        })
    }

    @Test("Two outlets crossing flag as an outlet clash")
    func outletsCross() {
        var doc = makeDoc()
        addPort(&doc, label: "P1", netLabel: "n1", at: Point(x: 25, y: 15), rotation: .r270) // down x=25
        addPort(&doc, label: "P2", netLabel: "n2", at: Point(x: 40, y: 5), rotation: .r180)  // left  y=5
        // Outlets meet at (25, 5).

        let issues = portBoreIssues(doc)
        #expect(issues.count == 1)
        #expect(issues.contains {
            if case .portBoreClearance(_, _, .outlet, _, _, _, _, _, _) = $0.kind { return true }
            return false
        })
    }

    @Test("A lone outlet with a clear run to the edge does not flag")
    func loneOutletIsFine() {
        var doc = makeDoc()
        addPort(&doc, label: "P1", netLabel: "np", at: Point(x: 25, y: 15), rotation: .r270)
        #expect(portBoreIssues(doc).isEmpty)
    }

    @Test("An outlet crossing its own net's channel does not flag")
    func sameNetChannelIgnored() {
        var doc = makeDoc()
        let (_, net) = addPort(&doc, label: "P1", netLabel: "np", at: Point(x: 25, y: 15), rotation: .r270)
        // Channel on the *same* net crossing the outlet path — shared fluid, not a clash.
        doc.physical.routes.append(Route(netId: net, segments: [
            Segment(
                waypoints: [Waypoint(position: Point(x: 10, y: 5)), Waypoint(position: Point(x: 40, y: 5))],
                layer: Layer(plate: .top, depth: 0)
            )
        ]))
        #expect(portBoreIssues(doc).isEmpty)
    }

    @Test("Outlets on different plate-layers don't clash")
    func differentLayersDoNotClash() {
        var doc = makeDoc()
        addPort(&doc, label: "P1", netLabel: "n1", at: Point(x: 25, y: 15), rotation: .r270, layer: .top)
        addPort(&doc, label: "P2", netLabel: "n2", at: Point(x: 40, y: 5), rotation: .r180, layer: .bottom)
        // Same XY paths as `outletsCross`, but on opposite plates.
        #expect(portBoreIssues(doc).isEmpty)
    }
}
