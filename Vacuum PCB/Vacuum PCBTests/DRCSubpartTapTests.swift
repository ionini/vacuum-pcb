import Testing
import Foundation
@testable import Vacuum_PCB

/// Taps (touch pads and testing points) inside a placed sub-part print as
/// holes in the PARENT's plates, so the parent-level tap-clearance check must
/// see them against the parent's own channels. Two things used to hide them
/// (found 2026-09-10 on Test Rig 4bit, whose pads live in four Test Rig 1bit
/// instances): the flatten re-mints hoisted component ids without hoisting
/// the sub-part's `Net`s, so a hoisted pad's netlist lookup failed and the
/// pad was skipped; and `physical.testPoints` were never hoisted at all.
@MainActor
struct DRCSubpartTapTests {

    private let top0 = Layer(plate: .top, depth: 0)

    /// 20×20 library part with one net "N" routed (2,10)→(10,10) on Top-L0,
    /// optionally ending in a touch pad T1 at (10,10) and/or carrying a
    /// testing point TP1 at 4 mm along that route ((6,10)).
    private func childPart(touchPad: Bool, testPoint: Bool) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 20, height: 20))
        doc.skipEdgeWallDRC = true
        var pins: [PinRef] = []
        if touchPad {
            let pad = Component(kind: .touchPad, label: "T1")
            doc.logic.components.append(pad)
            doc.physical.placements.append(Placement(
                componentId: pad.id, position: Point(x: 10, y: 10), rotation: .r0, layer: .top, depth: 0))
            pins.append(PinRef(componentId: pad.id, pinKey: "p"))
        }
        let net = Net(label: "N", pins: pins)
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 2, y: 10)),
                                Waypoint(position: Point(x: 10, y: 10))], layer: top0)
        ]))
        if testPoint {
            doc.physical.testPoints.append(TestPoint(
                name: "TP1", netId: net.id, segmentIndex: 0, offset: 4,
                plate: .top, depth: 0, position: Point(x: 6, y: 10)))
        }
        return doc
    }

    private func parentDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        return doc
    }

    /// Child (0,0) maps to world `p` (rotation r0).
    @discardableResult
    private func embed(_ child: CircuitDocument, in parent: inout CircuitDocument,
                       label: String, at p: Point, hash: String) -> UUID {
        var comp = Component(kind: .subpart, label: label)
        comp.partRef = "\(hash).vpcb"
        comp.partRefHash = hash
        parent.logic.components.append(comp)
        parent.librarySnapshots[hash] = child
        parent.physical.placements.append(Placement(
            componentId: comp.id, position: p, rotation: .r0, layer: .top, depth: 0))
        return comp.id
    }

    private func addRoute(_ doc: inout CircuitDocument, label: String,
                          from a: Point, to b: Point, layer: Layer? = nil) {
        let net = Net(label: label, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: layer ?? top0)
        ]))
    }

    private func tapIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter { if case .testPointClearance = $0.kind { return true }; return false }
    }

    // Default constants: channelDiameter 1.5, portBoreDiameter 1.7, min wall
    // 0.5 → a channel 1 mm from a tap centre leaves a negative wall.

    @Test("A parent channel skimming a sub-part touch pad flags at the parent level")
    func parentChannelNearHoistedPad() {
        var parent = parentDoc()
        let child = childPart(touchPad: true, testPoint: false)
        let instance = embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        // Pad lands at world (20,20); the parent's VAC runs 1 mm above it.
        addRoute(&parent, label: "VAC", from: Point(x: 12, y: 21), to: Point(x: 28, y: 21))

        let issues = tapIssues(parent)
        #expect(issues.count == 1)
        #expect(issues.contains {
            guard case .testPointClearance(_, "U1.T1", .channel, "VAC", _, _, let pos) = $0.kind
            else { return false }
            return pos == Point(x: 20, y: 20) && $0.severity == .error && $0.netLabel == "U1.N"
        })
        // The parent canvas can't select the hoisted pad; the instance is
        // the handle to move.
        if let issue = issues.first {
            let sel = DRC.physicalSelection(for: issue, in: parent)
            #expect(sel?.placements.contains(instance) == true)
        }
        // Standalone, the child is clean — the clash only exists in the parent.
        #expect(tapIssues(child).isEmpty)
    }

    @Test("A parent channel that continues the pad's own net (boundary unification) is ignored")
    func hoistedPadOwnNetViaUnificationIsFine() {
        var parent = parentDoc()
        var child = childPart(touchPad: true, testPoint: false)
        // Expose the child's net through a port so the parent can wire to it.
        let port = Component(kind: .port, label: "P")
        child.logic.components.append(port)
        child.physical.placements.append(Placement(
            componentId: port.id, position: Point(x: 0, y: 10), rotation: .r180, layer: .top, depth: 0))
        child.logic.nets[0].pins.append(PinRef(componentId: port.id, pinKey: "p"))
        let instance = embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h2")
        // Parent net N wired to the sub-part's boundary pin, routed to graze
        // the pad from 1 mm away — same net after unification, so no wall.
        let net = Net(label: "N", pins: [PinRef(componentId: instance, pinKey: port.id.uuidString)])
        parent.logic.nets.append(net)
        parent.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 10, y: 20)),
                                Waypoint(position: Point(x: 10, y: 21)),
                                Waypoint(position: Point(x: 20, y: 21))], layer: top0)
        ]))
        #expect(tapIssues(parent).isEmpty)
    }

    @Test("Sub-part testing points are hoisted and checked against parent channels")
    func parentChannelNearHoistedTestPoint() {
        var parent = parentDoc()
        let child = childPart(touchPad: false, testPoint: true)
        embed(child, in: &parent, label: "U2", at: Point(x: 10, y: 10), hash: "h3")
        // Bead lands at world (16,20); parent channel 1 mm below it.
        addRoute(&parent, label: "VAC", from: Point(x: 12, y: 19), to: Point(x: 28, y: 19))

        let flat = parent.flattened()
        #expect(flat.physical.testPoints.count == 1)
        #expect(flat.physical.testPoints.first.map { flat.physical.testPointWorld($0) } == Point(x: 16, y: 20))
        #expect(flat.physical.testPoints.first?.name == "U2.TP1")

        let issues = tapIssues(parent)
        #expect(issues.contains {
            guard case .testPointClearance(_, "U2.TP1", .channel, "VAC", _, _, let pos) = $0.kind
            else { return false }
            return pos == Point(x: 16, y: 20)
        })
    }

    @Test("Distant parent channels leave hoisted taps silent")
    func distantParentChannelIsFine() {
        var parent = parentDoc()
        let child = childPart(touchPad: true, testPoint: true)
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h4")
        addRoute(&parent, label: "VAC", from: Point(x: 12, y: 25), to: Point(x: 28, y: 25))
        #expect(tapIssues(parent).isEmpty)
    }
}
