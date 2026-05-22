import Foundation

/// Topology checks on the physical projection.
///
/// The schematic owns the netlist; the physical layout is a projection that
/// must realise it. Per-net we check that pins are joined by routed segments
/// (union-find on waypoints, same logic the CAD pipeline relies on), and we
/// cross-check pairs of route segments on each layer to make sure foreign
/// nets aren't within `manufacturing.minChannelSpacing` of each other.
///
/// What we *don't* check yet (deferred to a fuller iter-4 DRC):
/// - routes crossing foreign component exclusion zones
/// - pin/route layer mismatches
/// - net membership of route segments (we accept the document's `Route.netId`
///   without re-verifying that the segments only touch that net's pins —
///   the routing UI is supposed to enforce that at draw time).
/// - resistor serpentines and port bores in the clearance check (route
///   segments only for now).
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
            /// A via waypoint exists at this XY but has no matching via
            /// waypoint on the *opposite* layer's segment of the same net —
            /// the cross-plate bore is one-sided and won't connect through
            /// the silicone. `segmentIndex` is the index of the segment
            /// inside the issue's net that carries this orphan via, so the
            /// sidebar can select it on click.
            case orphanVia(position: Point, segmentIndex: Int)
            /// Two route segments belonging to different nets pass within
            /// `manufacturing.minChannelSpacing` of each other on the same
            /// plate. `selfSegmentIndex` is into the issue's net; the other
            /// pair (`otherNetId`, `otherSegmentIndex`) identifies the
            /// foreign segment so we can highlight both on click.
            case channelClearance(
                otherNetId: UUID,
                otherNetLabel: String,
                layer: Layer,
                gap: Double,
                selfSegmentIndex: Int,
                otherSegmentIndex: Int
            )
        }

        var summary: String {
            switch kind {
            case .unplacedPin(let p):
                return "\(netLabel): pin \(p.pinKey) is on an unplaced component"
            case .noRouteDrawn:
                return "\(netLabel): no route drawn"
            case .disconnectedPin(let p):
                return "\(netLabel): pin \(p.pinKey) unreached by routing"
            case .orphanVia(let p, _):
                return "\(netLabel): unpaired via at (\(String(format: "%.1f", p.x)), \(String(format: "%.1f", p.y)))"
            case .channelClearance(_, let other, let layer, let gap, _, _):
                let where_ = layer.uiLabel
                let gapTxt = gap < 0.01 ? "crossing" : "\(String(format: "%.2f", gap)) mm gap"
                return "\(netLabel) ↔ \(other) on \(where_): \(gapTxt)"
            }
        }
    }

    /// Maps an issue to a physical-canvas selection that highlights the
    /// offending elements. Returns `nil` if the issue can't be visualised
    /// on the physical view (e.g. an unplaced pin).
    static func physicalSelection(for issue: Issue, in document: CircuitDocument) -> PhysicalSelection? {
        switch issue.kind {
        case .unplacedPin:
            return nil
        case .noRouteDrawn:
            guard let net = document.logic.nets.first(where: { $0.id == issue.netId }) else { return nil }
            var sel = PhysicalSelection()
            sel.placements = Set(net.pins.map(\.componentId))
            return sel.isEmpty ? nil : sel
        case .disconnectedPin(let pinRef):
            return .placement(pinRef.componentId)
        case .orphanVia(_, let segIdx):
            return .routeSegment(netId: issue.netId, segmentIndex: segIdx)
        case let .channelClearance(otherNetId, _, _, _, selfSeg, otherSeg):
            // Highlight the self-segment as the focused route, and the
            // foreign segment via its waypoints so both halves of the
            // collision are visible at once. The placements set is left
            // empty so the user's attention stays on the routes.
            var sel = PhysicalSelection.routeSegment(netId: issue.netId, segmentIndex: selfSeg)
            if let otherRoute = document.physical.routes.first(where: { $0.netId == otherNetId }),
               otherSeg < otherRoute.segments.count {
                let segment = otherRoute.segments[otherSeg]
                for wIdx in 0..<segment.waypoints.count {
                    sel.waypoints.insert(RouteWaypointAddress(
                        netId: otherNetId, segmentIndex: otherSeg, waypointIndex: wIdx
                    ))
                }
            }
            return sel
        }
    }

    static func check(_ document: CircuitDocument) -> [Issue] {
        var issues: [Issue] = []
        for net in document.logic.nets {
            issues.append(contentsOf: checkNet(net, in: document))
        }
        issues.append(contentsOf: clearanceIssues(in: document))
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
        var netPinsByLayer: [Layer: [Point]] = [:]
        var issues: [Issue] = []
        for pinRef in net.pins {
            guard let placement = document.physical.placements.first(where: { $0.componentId == pinRef.componentId }),
                  let component = document.logic.components.first(where: { $0.id == pinRef.componentId }),
                  let fpPin = component.footprint(document.manufacturing, snapshots: document.librarySnapshots).pin(pinRef.pinKey)
            else {
                issues.append(Issue(netId: net.id, netLabel: net.label, kind: .unplacedPin(pinRef)))
                continue
            }
            let world = placement.worldPosition(of: fpPin)
            pinPositions[pinRef] = world
            let layer = placement.resolvedLayer(of: fpPin, on: component)
            netPinsByLayer[layer, default: []].append(world)
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
        // Pin-snap tolerance: matches PlateBuilder.extendedWaypointPositions
        // so a route end that drifts away from its pin (because padsOffset
        // moved) still counts as connected here.
        let pinSnapTol = document.manufacturing.dimpleDiameter / 2 + 0.01
        for segment in segments {
            let positions = PlateBuilder.extendedWaypointPositions(
                for: segment,
                pinsOnLayer: netPinsByLayer[segment.layer] ?? [],
                tolerance: pinSnapTol
            )
            guard positions.count >= 2 else { continue }
            let indices = positions.map { nodeIndex(for: $0) }
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

        // Every via must appear at the *same* XY on at least one segment per
        // layer; otherwise the cross-plate bore is one-sided.
        issues.append(contentsOf: viaIssues(
            net: net, segments: segments,
            pinPositions: Array(pinPositions.values)
        ))

        return issues
    }

    private static func viaIssues(
        net: Net, segments: [Segment], pinPositions: [Point]
    ) -> [Issue] {
        // Group via waypoints by approximate XY → which layers carry one,
        // and which segments hold them so the sidebar can select the
        // offending segment when the user clicks the issue.
        struct Group {
            var position: Point
            var layers: Set<Layer>
            var segmentIndices: [Int]
        }
        var groups: [Group] = []
        let eps = 0.05
        for (segIdx, segment) in segments.enumerated() {
            for wp in segment.waypoints where wp.kind == .via {
                if let i = groups.firstIndex(where: {
                    abs($0.position.x - wp.position.x) < eps && abs($0.position.y - wp.position.y) < eps
                }) {
                    groups[i].layers.insert(segment.layer)
                    groups[i].segmentIndices.append(segIdx)
                } else {
                    groups.append(Group(position: wp.position, layers: [segment.layer], segmentIndices: [segIdx]))
                }
            }
        }
        // A `.via` marker that sits on top of a placed pin of the same net is
        // decorative: the pin already anchors the channel at that XY, and
        // PlateBuilder skips single-layer via groups so no stray bore is
        // produced. Suppress those — true mid-route orphans (no pin nearby)
        // still report.
        func coincidesWithPin(_ p: Point) -> Bool {
            pinPositions.contains { abs($0.x - p.x) < eps && abs($0.y - p.y) < eps }
        }
        return groups
            .filter { $0.layers.count < 2 && !coincidesWithPin($0.position) }
            .map { Issue(
                netId: net.id, netLabel: net.label,
                kind: .orphanVia(position: $0.position, segmentIndex: $0.segmentIndices.first ?? 0)
            ) }
    }

    // MARK: - Channel clearance

    private struct ChannelEdge {
        let netId: UUID
        let netLabel: String
        let segmentIndex: Int
        let layer: Layer
        let a: Point
        let b: Point
    }

    /// Walks every pair of route polyline edges; if two edges on the same
    /// layer belong to different nets and pass within `minChannelSpacing`,
    /// emit one issue per (net-pair, layer) — we don't need to spam the
    /// sidebar with every offending segment, the user just needs to know
    /// "those two nets clash on top, look at the canvas".
    private static func clearanceIssues(in doc: CircuitDocument) -> [Issue] {
        let threshold = doc.manufacturing.minChannelSpacing
        let edges = collectRouteEdges(in: doc)
        guard edges.count >= 2 else { return [] }

        struct PairKey: Hashable {
            let first: UUID, second: UUID, layer: Layer
            init(_ a: UUID, _ b: UUID, _ layer: Layer) {
                let ordered = a.uuidString < b.uuidString ? (a, b) : (b, a)
                self.first = ordered.0; self.second = ordered.1; self.layer = layer
            }
        }
        var reported: Set<PairKey> = []
        var issues: [Issue] = []
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let a = edges[i], b = edges[j]
                if a.netId == b.netId { continue }
                if a.layer != b.layer { continue }
                let key = PairKey(a.netId, b.netId, a.layer)
                if reported.contains(key) { continue }
                let d = segmentDistance(a.a, a.b, b.a, b.b)
                guard d < threshold else { continue }
                reported.insert(key)
                issues.append(Issue(
                    netId: a.netId, netLabel: a.netLabel,
                    kind: .channelClearance(
                        otherNetId: b.netId, otherNetLabel: b.netLabel,
                        layer: a.layer, gap: d,
                        selfSegmentIndex: a.segmentIndex,
                        otherSegmentIndex: b.segmentIndex
                    )
                ))
            }
        }
        return issues
    }

    private static func collectRouteEdges(in doc: CircuitDocument) -> [ChannelEdge] {
        let labels = Dictionary(uniqueKeysWithValues: doc.logic.nets.map { ($0.id, $0.label) })
        var out: [ChannelEdge] = []
        for route in doc.physical.routes {
            let label = labels[route.netId] ?? "?"
            for (segIdx, seg) in route.segments.enumerated() {
                let pts = seg.waypoints
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    out.append(ChannelEdge(
                        netId: route.netId, netLabel: label,
                        segmentIndex: segIdx, layer: seg.layer,
                        a: pts[i].position, b: pts[i + 1].position
                    ))
                }
            }
        }
        return out
    }

    /// 2D point-to-point on collapsed segments, point-to-segment otherwise,
    /// and an explicit intersection test so two crossing edges produce a 0
    /// gap (the four-endpoint distances alone would miss that).
    private static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(
            min(pointSegmentDistance(a, c, d), pointSegmentDistance(b, c, d)),
            min(pointSegmentDistance(c, a, b), pointSegmentDistance(d, a, b))
        )
    }

    private static func pointSegmentDistance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else {
            let ex = p.x - a.x, ey = p.y - a.y
            return (ex * ex + ey * ey).squareRoot()
        }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        let projX = a.x + t * dx
        let projY = a.y + t * dy
        let ex = p.x - projX, ey = p.y - projY
        return (ex * ex + ey * ey).squareRoot()
    }

    private static func segmentsIntersect(_ p1: Point, _ p2: Point, _ p3: Point, _ p4: Point) -> Bool {
        func cross(_ a: Point, _ b: Point, _ c: Point) -> Double {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        let d1 = cross(p3, p4, p1)
        let d2 = cross(p3, p4, p2)
        let d3 = cross(p1, p2, p3)
        let d4 = cross(p1, p2, p4)
        return ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0))
            && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0))
    }
}
