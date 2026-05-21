import Foundation

/// One pending connection in the physical view's ratsnest overlay: a pair of
/// placed pins that are on the same net but still aren't joined by any
/// routed channel. Rendered as a thin dashed hint so the user can see at a
/// glance what's left to route.
struct RatsnestEdge: Hashable {
    let netId: UUID
    let netLabel: String
    let a: Point
    let b: Point
}

enum Ratsnest {
    /// Returns the minimal set of "still-missing" connections per net.
    ///
    /// Algorithm per net:
    ///   * Union-find over every routed segment's waypoints (matching DRC,
    ///     same 0.05 mm tolerance). Pin positions fold into the same graph
    ///     so a segment endpoint sitting on a pin merges them.
    ///   * Start a second union-find over the net's *placed* pins, pre-
    ///     merging any pair that ended up in the same route-graph component.
    ///   * Kruskal's MST on the pin pair distances: every pair that doesn't
    ///     yet share a component becomes a ratsnest edge, and the union is
    ///     merged so the next cheapest disconnect picks up where this left
    ///     off. Fully-routed nets emit nothing; nets with no routes emit
    ///     N-1 edges (the natural pin-to-pin spanning tree).
    static func missingEdges(_ doc: CircuitDocument) -> [RatsnestEdge] {
        var result: [RatsnestEdge] = []
        for net in doc.logic.nets {
            result.append(contentsOf: missingEdges(net: net, in: doc))
        }
        return result
    }

    private static func missingEdges(net: Net, in doc: CircuitDocument) -> [RatsnestEdge] {
        guard net.pins.count >= 2 else { return [] }

        // 1. Resolve placed pin world positions + the owning component's
        //    kind (so we can pick a port / rail anchor below).
        struct PlacedPin {
            let ref: PinRef
            let position: Point
            let kind: ComponentKind
            let layer: Layer
        }
        var placedPins: [PlacedPin] = []
        var netPinsByLayer: [Layer: [Point]] = [:]
        for pinRef in net.pins {
            guard let placement = doc.physical.placements.first(where: { $0.componentId == pinRef.componentId }),
                  let component = doc.logic.components.first(where: { $0.id == pinRef.componentId }),
                  let fpPin = component.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pin(pinRef.pinKey)
            else { continue }
            let world = placement.worldPosition(of: fpPin)
            let layer = placement.resolvedLayer(of: fpPin, on: component)
            placedPins.append(PlacedPin(
                ref: pinRef, position: world, kind: component.kind, layer: layer
            ))
            netPinsByLayer[layer, default: []].append(world)
        }
        guard placedPins.count >= 2 else { return [] }

        // 2. Union-find on segment waypoints + pin positions.
        var nodes: [Point] = []
        let eps = 0.05
        func nodeIndex(for p: Point) -> Int {
            for (i, q) in nodes.enumerated() {
                if abs(q.x - p.x) < eps && abs(q.y - p.y) < eps { return i }
            }
            nodes.append(p)
            return nodes.count - 1
        }
        var parent: [Int] = []
        func ensure(_ i: Int) {
            while parent.count <= i { parent.append(parent.count) }
        }
        func find(_ x: Int) -> Int {
            ensure(x)
            var c = x
            while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }
            return c
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }

        let pinNodes = placedPins.map { nodeIndex(for: $0.position) }
        // Pin-snap tolerance matches the CAD pipeline so a small drift between
        // a route end and its pin (e.g. from changing padsOffset) still counts
        // as connected — no phantom missing-edge line in the ratsnest.
        let pinSnapTol = doc.manufacturing.dimpleDiameter / 2 + 0.5
        for route in doc.physical.routes where route.netId == net.id {
            for segment in route.segments {
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
        }

        // 3. Second union-find on pins, seeded by route-graph components so
        // that pins already electrically connected don't generate ratsnest
        // edges between themselves.
        var pinUF = Array(0..<placedPins.count)
        func pinFind(_ x: Int) -> Int {
            var c = x
            while pinUF[c] != c { pinUF[c] = pinUF[pinUF[c]]; c = pinUF[c] }
            return c
        }
        func pinUnion(_ a: Int, _ b: Int) {
            let ra = pinFind(a), rb = pinFind(b)
            if ra != rb { pinUF[ra] = rb }
        }
        for i in 0..<placedPins.count {
            for j in (i + 1)..<placedPins.count where find(pinNodes[i]) == find(pinNodes[j]) {
                pinUnion(i, j)
            }
        }

        // 4. Pick the layout strategy, mirroring NetEdgeBuilder on the
        // schematic side so the two views agree:
        //   * If the net has a port (input/output) → star from it.
        //   * Else if a rail (vac / vent) → star from it.
        //   * Else fall back to Kruskal MST.
        // Routes already drawn pre-merge their pins so an anchored star
        // doesn't redraw a connection the user already routed.
        let anchorIdx: Int? = {
            if let i = placedPins.firstIndex(where: { $0.kind == .port }) { return i }
            if let i = placedPins.firstIndex(where: {
                $0.kind == .vacuumSource || $0.kind == .atmVent
            }) { return i }
            return nil
        }()

        if let anchorIdx {
            var edges: [RatsnestEdge] = []
            let anchor = placedPins[anchorIdx]
            for i in 0..<placedPins.count where i != anchorIdx {
                if pinFind(anchorIdx) == pinFind(i) { continue }
                pinUnion(anchorIdx, i)
                edges.append(RatsnestEdge(
                    netId: net.id, netLabel: net.label,
                    a: anchor.position,
                    b: placedPins[i].position
                ))
            }
            return edges
        }

        // 5. Kruskal's MST fallback for component-only nets.
        struct Edge { let i: Int; let j: Int; let d: Double }
        var pairs: [Edge] = []
        pairs.reserveCapacity(placedPins.count * (placedPins.count - 1) / 2)
        for i in 0..<placedPins.count {
            for j in (i + 1)..<placedPins.count {
                let dx = placedPins[i].position.x - placedPins[j].position.x
                let dy = placedPins[i].position.y - placedPins[j].position.y
                pairs.append(Edge(i: i, j: j, d: dx * dx + dy * dy))
            }
        }
        pairs.sort { $0.d < $1.d }

        var edges: [RatsnestEdge] = []
        for pair in pairs {
            if pinFind(pair.i) == pinFind(pair.j) { continue }
            pinUnion(pair.i, pair.j)
            edges.append(RatsnestEdge(
                netId: net.id, netLabel: net.label,
                a: placedPins[pair.i].position,
                b: placedPins[pair.j].position
            ))
        }
        return edges
    }
}
