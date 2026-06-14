import Testing
import Foundation
@testable import Vacuum_PCB

/// `CircuitDocument.skipEdgeWallDRC` marks a design as a reusable sub-component
/// whose `boardOutline` is not a real outer face (it gets embedded inside a
/// larger plate). When set, DRC drops the board-edge thin-wall warnings
/// (`thinWall(.outerFace)`) for that document only — the internal channel/bore
/// wall checks still run, and because `thinWallIssues` reads the unflattened
/// top-level doc and never touches `librarySnapshots`, a parent that embeds the
/// part re-checks its own edges with its own (default-off) flag.
@MainActor
struct DRCEdgeWallSuppressionTests {

    private func makeDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 50, height: 30))
        return doc
    }

    /// A bare two-waypoint channel on its own pin-less net (enough for the
    /// thin-wall geometry; topology checks ignore an empty net).
    @discardableResult
    private func addChannel(
        _ doc: inout CircuitDocument, netLabel: String, from a: Point, to b: Point,
        layer: Layer? = nil
    ) -> UUID {
        let net = Net(label: netLabel, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)],
                    layer: layer ?? Layer(plate: .top, depth: 0))
        ]))
        return net.id
    }

    private func thinWall(_ doc: CircuitDocument, _ neighbor: ThinWallNeighbor) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .thinWall(let n, _, _, _, _) = $0.kind, n == neighbor { return true }
            return false
        }
    }

    @Test("Board-edge thin wall fires when the design is not flagged")
    func edgeWallFiresWhenNotFlagged() {
        var doc = makeDoc()
        // Channel 1 mm in from the bottom edge → wall = 1.0 − 0.75 = 0.25 mm < 0.5.
        addChannel(&doc, netLabel: "n1", from: Point(x: 10, y: 1), to: Point(x: 40, y: 1))
        #expect(doc.skipEdgeWallDRC == nil)        // default: off
        #expect(!thinWall(doc, .outerFace).isEmpty)
    }

    @Test("Flagging the design suppresses the board-edge thin wall")
    func edgeWallSuppressedWhenFlagged() {
        var doc = makeDoc()
        addChannel(&doc, netLabel: "n1", from: Point(x: 10, y: 1), to: Point(x: 40, y: 1))
        doc.skipEdgeWallDRC = true
        #expect(thinWall(doc, .outerFace).isEmpty)
    }

    @Test("Internal bore thin wall still fires while the flag is set")
    func internalBoreWallStillFiresWhenFlagged() {
        var doc = makeDoc()
        // A via bore mid-board (one waypoint → no channel edge, just a bore).
        let viaNet = Net(label: "nv", pins: [])
        doc.logic.nets.append(viaNet)
        doc.physical.routes.append(Route(netId: viaNet.id, segments: [
            Segment(waypoints: [Waypoint(position: Point(x: 25, y: 15), kind: .via)],
                    layer: Layer(plate: .top, depth: 0))
        ]))
        // A foreign-net channel passing 1 mm from the via on the same layer →
        // wall = 1.0 − 0.75 − 0.75 < 0.5, well clear of every board edge.
        addChannel(&doc, netLabel: "nc", from: Point(x: 10, y: 15), to: Point(x: 24, y: 15))

        doc.skipEdgeWallDRC = true
        #expect(thinWall(doc, .outerFace).isEmpty)   // edge check gone…
        #expect(!thinWall(doc, .bore).isEmpty)        // …bore check stays
    }

    @Test("The flag is excluded from content/effective hashes")
    func flagDoesNotChangeHashes() {
        var doc = makeDoc()
        addChannel(&doc, netLabel: "n1", from: Point(x: 10, y: 1), to: Point(x: 40, y: 1))
        let contentOff = doc.contentHash()
        let effectiveOff = doc.effectiveHash()
        doc.skipEdgeWallDRC = true
        // Pure annotation: toggling it must not re-pin snapshots or trip
        // "Library has changes" staleness in any parent that embeds this part.
        #expect(doc.contentHash() == contentOff)
        #expect(doc.effectiveHash() == effectiveOff)
    }
}
