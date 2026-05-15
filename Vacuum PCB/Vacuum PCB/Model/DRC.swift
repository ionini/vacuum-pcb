import Foundation

/// Topology checks on the physical projection.
///
/// The schematic owns the netlist; the physical layout is a projection that
/// must realise it. Right now we check exactly one thing per net: are all of
/// its pins connected to each other through routed segments?
///
/// Two segments are considered electrically (pneumatically) joined when they
/// share a waypoint position. Pin world positions count as waypoints for this
/// purpose, so a segment whose endpoint sits on a pin connects to that pin.
/// This matches the CAD pipeline: channel meshes union together at shared
/// waypoints via sphere joints.
///
/// What we *don't* check yet (deferred to a fuller iter-4 DRC):
/// - routes crossing foreign component exclusion zones
/// - pin/route layer mismatches
/// - minimum channel spacing
/// - net membership of route segments (we accept the document's `Route.netId`
///   without re-verifying that the segments only touch that net's pins —
///   the routing UI is supposed to enforce that at draw time).
enum DRC {
    struct Issue: Identifiable, Hashable {
        let id = UUID()
        let netId: UUID
        let netLabel: String
        let kind: Kind

        enum Kind: Hashable {
            /// The component that owns this pin has no placement, so we can't
            /// even tell where the pin sits to verify it. Place the component
            /// in the parking lot → board to clear this.
            case unplacedPin(PinRef)
            /// The net has at least two placed pins but no routes attached to
            /// its netId — nothing has been drawn yet.
            case noRouteDrawn
            /// The pin is placed but the routed segment graph does not reach
            /// it from the rest of the net's pins. Either the user hasn't
            /// finished routing or a segment endpoint isn't quite on the pin.
            case disconnectedPin(PinRef)
        }

        var summary: String {
            switch kind {
            case .unplacedPin(let p):
                return "\(netLabel): pin \(p.pinKey) is on an unplaced component"
            case .noRouteDrawn:
                return "\(netLabel): no route drawn"
            case .disconnectedPin(let p):
                return "\(netLabel): pin \(p.pinKey) unreached by routing"
            }
        }
    }

    static func check(_ document: CircuitDocument) -> [Issue] {
        var issues: [Issue] = []
        for net in document.logic.nets {
            issues.append(contentsOf: checkNet(net, in: document))
        }
        return issues
    }

    private static func checkNet(_ net: Net, in document: CircuitDocument) -> [Issue] {
        // A net with fewer than two pins is trivially "connected" (or doesn't
        // need a wire). It also gets pruned by the schematic editor anyway.
        guard net.pins.count >= 2 else { return [] }

        // Resolve pin world positions. Anything unplaced is a separate issue
        // (we can't reason about its connectivity yet) and disqualifies the
        // pin from the union-find pass.
        var pinPositions: [PinRef: Point] = [:]
        var issues: [Issue] = []
        for pinRef in net.pins {
            guard let placement = document.physical.placements.first(where: { $0.componentId == pinRef.componentId }),
                  let component = document.logic.components.first(where: { $0.id == pinRef.componentId }),
                  let fpPin = component.footprint.pin(pinRef.pinKey)
            else {
                issues.append(Issue(netId: net.id, netLabel: net.label, kind: .unplacedPin(pinRef)))
                continue
            }
            pinPositions[pinRef] = placement.worldPosition(of: fpPin)
        }
        guard pinPositions.count >= 2 else { return issues }

        let routes = document.physical.routes.filter { $0.netId == net.id }
        let segments = routes.flatMap(\.segments)
        guard !segments.isEmpty else {
            issues.append(Issue(netId: net.id, netLabel: net.label, kind: .noRouteDrawn))
            return issues
        }

        // Map points to integer node ids using a tolerance so floating point
        // chatter on grid-snapped coords doesn't fragment the graph.
        var nodes: [Point] = []
        let epsilon = 0.05
        func nodeIndex(for p: Point) -> Int {
            for (i, q) in nodes.enumerated() {
                if abs(q.x - p.x) < epsilon && abs(q.y - p.y) < epsilon {
                    return i
                }
            }
            nodes.append(p)
            return nodes.count - 1
        }

        // Union-find on the waypoint graph: each segment unions its consecutive
        // waypoints into one component. Pins are inserted as their own nodes
        // beforehand so coincident positions resolve to the same node id.
        var parent: [Int] = []
        func ensure(_ i: Int) {
            while parent.count <= i { parent.append(parent.count) }
        }
        func find(_ x: Int) -> Int {
            ensure(x)
            var current = x
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        var pinNodes: [PinRef: Int] = [:]
        for (pinRef, pos) in pinPositions {
            pinNodes[pinRef] = nodeIndex(for: pos)
        }
        for segment in segments {
            guard segment.waypoints.count >= 2 else { continue }
            let indices = segment.waypoints.map { nodeIndex(for: $0.position) }
            for i in 0..<(indices.count - 1) {
                union(indices[i], indices[i + 1])
            }
        }

        // All placed pins must share a root with the first placed pin.
        let roots = pinNodes.mapValues { find($0) }
        guard let referenceRoot = roots.values.first else { return issues }
        for (pinRef, root) in roots where root != referenceRoot {
            issues.append(Issue(netId: net.id, netLabel: net.label, kind: .disconnectedPin(pinRef)))
        }
        return issues
    }
}
