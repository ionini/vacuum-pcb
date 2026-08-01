import Testing
import Foundation
@testable import Vacuum_PCB

/// The wall checks run on the *flattened* doc: sub-part internals are checked
/// with the PARENT's constants (that's what they print with) against the
/// parent's own routes, the parent's board edge, and other sub-parts. Findings
/// with a sub-part side report as `.subpartWall`; parent-only findings keep
/// their classic kinds. Socket-mated assemblies are exempt — their sub-parts
/// stack at one origin and print separately. `preferredWallThickness` adds a
/// warning tier between the hard minimum and the comfort wall.
@MainActor
struct DRCSubpartWallTests {

    private let top0 = Layer(plate: .top, depth: 0)

    /// Child library part: 20×20 board with one horizontal Top-L0 channel
    /// (x 2→18) per entry. Flagged reusable so its own outline doesn't
    /// produce edge-wall noise in either the standalone or embedded checks.
    private func childPart(routesAtY: [(label: String, y: Double)]) -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 20, height: 20))
        doc.skipEdgeWallDRC = true
        for r in routesAtY {
            let net = Net(label: r.label, pins: [])
            doc.logic.nets.append(net)
            doc.physical.routes.append(Route(netId: net.id, segments: [
                Segment(waypoints: [
                    Waypoint(position: Point(x: 2, y: r.y)),
                    Waypoint(position: Point(x: 18, y: r.y)),
                ], layer: top0)
            ]))
        }
        return doc
    }

    private func parentDoc() -> CircuitDocument {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 80, height: 40))
        return doc
    }

    /// Places `child` as a snapshot-pinned sub-part. Child (0,0) maps to
    /// world `p` (rotation r0), so a child channel at y=cy lands at p.y+cy.
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
                          from a: Point, to b: Point) {
        let net = Net(label: label, pins: [])
        doc.logic.nets.append(net)
        doc.physical.routes.append(Route(netId: net.id, segments: [
            Segment(waypoints: [Waypoint(position: a), Waypoint(position: b)], layer: top0)
        ]))
    }

    private func subpartWalls(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .subpartWall = $0.kind { return true }
            return false
        }
    }

    private func channelClearances(_ doc: CircuitDocument) -> [DRC.Issue] {
        DRC.check(doc).filter {
            if case .channelClearance = $0.kind { return true }
            return false
        }
    }

    // Default constants: channelDiameter 1.5, minWallThickness 0.5 —
    // centre-to-centre = 1.5 + wall throughout.

    @Test("Parent route skimming a sub-part channel flags a sub-part wall error")
    func parentRouteNearSubpartChannel() {
        var parent = parentDoc()
        let child = childPart(routesAtY: [("cn", 10)])
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        // Child channel lands at world y = 20; the parent's own route runs
        // 1.8 mm away → 0.3 mm wall against the 0.5 mm minimum.
        addRoute(&parent, label: "pn", from: Point(x: 12, y: 21.8), to: Point(x: 28, y: 21.8))

        let walls = subpartWalls(parent)
        #expect(walls.contains { issue in
            guard case .subpartWall(let neighbor, _, _, _, let wall, _) = issue.kind
            else { return false }
            return neighbor == .channel && issue.severity == .error
                && wall > 0.25 && wall < 0.35
        })
        // The sub-part side is named with its instance chain.
        #expect(walls.contains { $0.netLabel == "U1.cn" })
    }

    @Test("Distant sub-part channels stay silent")
    func distantSubpartChannelIsFine() {
        var parent = parentDoc()
        let child = childPart(routesAtY: [("cn", 10)])
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        addRoute(&parent, label: "pn", from: Point(x: 12, y: 24.5), to: Point(x: 28, y: 24.5))
        #expect(subpartWalls(parent).isEmpty)
    }

    @Test("Sub-part internals are checked with the parent's constants")
    func subpartInternalsUseParentConstants() {
        // 2.1 mm centre-to-centre → 0.6 mm wall: clean in the child's own
        // file (its min wall is 0.5)…
        let child = childPart(routesAtY: [("a", 9), ("b", 11.1)])
        #expect(channelClearances(child).isEmpty)

        // …but the parent prints those channels with ITS wall budget.
        var parent = parentDoc()
        parent.manufacturing.minWallThickness = 0.8
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        #expect(subpartWalls(parent).contains { $0.severity == .error })
    }

    @Test("Sub-part channel near the parent's board edge flags an outer-face wall")
    func subpartNearParentEdge() {
        let child = childPart(routesAtY: [("cn", 10)])
        // The child is edge-clean in its own file (reusable flag), but placed
        // so its channel lands 1 mm from the parent's y=0 edge → 0.25 mm wall.
        var parent = parentDoc()
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: -9), hash: "h1")
        #expect(subpartWalls(parent).contains { issue in
            guard case .subpartWall(let neighbor, _, _, _, _, _) = issue.kind
            else { return false }
            return neighbor == .outerFace && issue.severity == .error
        })
    }

    @Test("Two sub-parts placed too close flag against each other")
    func twoSubpartsTooClose() {
        let child = childPart(routesAtY: [("cn", 10)])
        var parent = parentDoc()
        // Channels land at world y = 20 and y = 21.8 → 0.3 mm wall.
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        embed(child, in: &parent, label: "U2", at: Point(x: 10, y: 11.8), hash: "h1")
        #expect(subpartWalls(parent).contains { $0.severity == .error })
    }

    @Test("Socket-mated assemblies skip the flattened wall checks")
    func assemblySkipsFlattenedWalls() {
        let child = childPart(routesAtY: [("cn", 10)])
        var parent = parentDoc()
        // Stacked at one origin — the assembly convention. Without matings
        // this is a genuine clash…
        embed(child, in: &parent, label: "U1", at: Point(x: 10, y: 10), hash: "h1")
        embed(child, in: &parent, label: "U2", at: Point(x: 10, y: 10), hash: "h1")
        #expect(!subpartWalls(parent).isEmpty)
        // …but as soon as the doc is an assembly, the parts print separately
        // and flattened proximity is meaningless.
        parent.logic.matings = [Mating(a: .topLevel(componentId: UUID()),
                                       b: .topLevel(componentId: UUID()))]
        #expect(subpartWalls(parent).isEmpty)
    }

    @Test("Preferred wall adds a warning tier between min and preferred")
    func preferredWallWarningTier() {
        var doc = parentDoc()
        addRoute(&doc, label: "a", from: Point(x: 10, y: 20.0), to: Point(x: 40, y: 20.0))
        addRoute(&doc, label: "b", from: Point(x: 10, y: 22.2), to: Point(x: 40, y: 22.2))
        // 0.7 mm wall: silent without a preferred wall…
        #expect(channelClearances(doc).isEmpty)

        doc.manufacturing.preferredWallThickness = 1.0
        let tiered = channelClearances(doc)
        #expect(tiered.count == 1)
        #expect(tiered.allSatisfy { $0.severity == .warning })

        // …and a third route at 0.3 mm wall still reports as a hard error.
        addRoute(&doc, label: "c", from: Point(x: 10, y: 24.0), to: Point(x: 40, y: 24.0))
        let mixed = channelClearances(doc)
        #expect(mixed.contains { $0.severity == .error })
        #expect(mixed.contains { $0.severity == .warning })
    }

    @Test("Boards without sub-parts behave exactly as before")
    func noSubpartsUnchanged() {
        var doc = parentDoc()
        addRoute(&doc, label: "a", from: Point(x: 10, y: 20.0), to: Point(x: 40, y: 20.0))
        addRoute(&doc, label: "b", from: Point(x: 10, y: 21.8), to: Point(x: 40, y: 21.8))
        let issues = channelClearances(doc)
        #expect(issues.count == 1)
        #expect(issues.allSatisfy { $0.severity == .error })
        #expect(subpartWalls(doc).isEmpty)
    }
}
