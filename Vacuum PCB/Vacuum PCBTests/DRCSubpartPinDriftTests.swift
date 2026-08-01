import Testing
import Foundation
@testable import Vacuum_PCB

/// `subpartPinDrift`: the flatten computes hoisted pin positions with the
/// PARENT's constants while the sub-part's routes were drawn against its own
/// file's — a padsOffset mismatch prints every routed pad bore off-centre
/// from its channel end. Drift in (0.05 mm, channelRadius) reports a
/// warning; matching constants stay silent, and the warning never fails the
/// connectivity gate.
@MainActor
struct DRCSubpartPinDriftTests {

    private let bottom0 = Layer(plate: .bottom, depth: 0)

    /// Child part: 30×20 board, one transistor at (15,10) placed on top (so
    /// its "a"/"b" pads drop on the bottom plate), pin "a" routed 8 mm north
    /// on B0 from the pin position the child's OWN padsOffset gives it.
    private func childWithRoutedPad(padsOffset: Double) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 30, height: 20))
        doc.skipEdgeWallDRC = true
        doc.manufacturing.padsOffset = padsOffset
        let q = Component(kind: .transistor, label: "Q1")
        doc.logic.components.append(q)
        let pl = Placement(componentId: q.id, position: Point(x: 15, y: 10),
                           rotation: .r0, layer: .top, depth: 0)
        doc.physical.placements.append(pl)
        let pinA = q.footprint(doc.manufacturing).pin("a")!
        let start = pl.worldPosition(of: pinA)
        let net = Net(label: "n1", pins: [PinRef(componentId: q.id, pinKey: "a")])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [
                Waypoint(position: start),
                Waypoint(position: Point(x: start.x, y: start.y + 8)),
            ], layer: bottom0)
        ]))
        return doc
    }

    private func parent(childPadsOffset: Double,
                        parentPadsOffset: Double) -> CircuitDocument {
        var parent = CircuitDocument.blank()
        parent.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        parent.manufacturing.padsOffset = parentPadsOffset
        let child = childWithRoutedPad(padsOffset: childPadsOffset)
        var comp = Component(kind: .subpart, label: "U1")
        comp.partRef = "drift-child.vpcb"
        comp.partRefHash = "h-drift"
        parent.logic.components.append(comp)
        parent.librarySnapshots["h-drift"] = child
        parent.physical.placements.append(Placement(
            componentId: comp.id, position: Point(x: 20, y: 10),
            rotation: .r0, layer: .top, depth: 0))
        return parent
    }

    private func driftIssues(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .subpartPinDrift = $0.kind { return true }
            return false
        }
    }

    @Test("padsOffset mismatch reports one drift warning with the offset")
    func padsOffsetMismatchWarns() {
        // Child routed at 1.5, parent prints at 1.25 → the routed pad "a"
        // lands 0.25 mm off its channel. Pin "b" is unrouted (nothing plumbs
        // it) and the gate's plate has no routes — neither may report.
        let doc = parent(childPadsOffset: 1.5, parentPadsOffset: 1.25)
        let issues = driftIssues(doc)
        #expect(issues.count == 1)
        var matched = false
        if case let .subpartPinDrift(label, pinKey, drift, layer, _)? = issues.first?.kind {
            matched = true
            #expect(label == "U1.Q1")
            #expect(pinKey == "a")
            #expect(drift > 0.2 && drift < 0.3)
            #expect(layer.plate == .bottom)
        }
        #expect(matched)
        #expect(issues.allSatisfy { $0.severity == .warning })
        // A drifted-but-working pad must not fail the connectivity gate.
        #expect(Validators.connectivity(doc).pass)
    }

    @Test("matching constants stay silent")
    func matchingConstantsSilent() {
        let doc = parent(childPadsOffset: 1.25, parentPadsOffset: 1.25)
        #expect(driftIssues(doc).isEmpty)
    }
}
