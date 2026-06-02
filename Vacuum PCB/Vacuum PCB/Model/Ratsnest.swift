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
    /// Layer of the pin at each endpoint, so the physical overlay can hide
    /// edges that dangle into hidden layers.
    let layerA: Layer
    let layerB: Layer
}

enum Ratsnest {
    /// Returns the minimal set of "still-missing" connections per net.
    ///
    /// Algorithm per net:
    ///   * Union-find over every routed segment's waypoints, keyed by
    ///     (layer, XY) at 0.05 mm tolerance. Layer matters: two segments
    ///     crossing the same point on different layers are physically
    ///     separate, joined only by a real via (a `.via` marker on ≥2 layers,
    ///     the bore PlateBuilder actually cuts) or by a pin whose bore bridges
    ///     them. A single-layer "orphan" via joins nothing — so a net that's
    ///     broken at one no longer reports as routed. Pin positions fold into
    ///     the same graph so a segment endpoint sitting on a pin merges them.
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

        // 2. Union-find over routed geometry, keyed by (layer, XY) — not XY
        //    alone. Two segments crossing the same point on different layers
        //    are physically separate; they connect only at a real junction (a
        //    via through ≥2 layers, or a pin bore). Keying by layer is what
        //    lets the ratsnest notice an "orphan" via — a `.via` marker on a
        //    single layer, which PlateBuilder silently drops — instead of
        //    reporting a net as routed when the printed board would be open.
        struct LayerPoint { let layer: Layer; let p: Point }
        var nodes: [LayerPoint] = []
        let eps = 0.05
        func nodeIndex(_ layer: Layer, _ p: Point) -> Int {
            for (i, q) in nodes.enumerated() {
                if q.layer == layer && abs(q.p.x - p.x) < eps && abs(q.p.y - p.y) < eps { return i }
            }
            nodes.append(LayerPoint(layer: layer, p: p))
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

        let pinNodes = placedPins.map { nodeIndex($0.layer, $0.position) }
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
                let indices = positions.map { nodeIndex(segment.layer, $0) }
                for i in 0..<(indices.count - 1) {
                    union(indices[i], indices[i + 1])
                }
            }
        }

        // Layer transitions. A via bores through every layer carrying a `.via`
        // marker at its XY; PlateBuilder only cuts that bore when ≥2 layers
        // meet, so that's exactly when the ratsnest may join them. A
        // single-layer (orphan) via joins nothing, and the gap it leaves now
        // surfaces as a missing edge instead of a phantom completed net.
        for group in doc.physical.viaLayerGroups(netId: net.id) where group.layers.count >= 2 {
            let layerNodes = group.layers.map { nodeIndex($0, group.position) }
            for k in layerNodes.dropFirst() { union(layerNodes[0], k) }
        }

        // A pin is NOT a layer junction: its bore anchors the channel only on
        // the pin's own layer — a B0 input pin doesn't pull a B1 segment up to
        // it. Same-layer connections are already covered (the pin node and a
        // coincident segment endpoint share the same (layer, XY) key), so a
        // route changing layer at a pin still needs a real via there. This is
        // deliberately stricter than DRC's `orphanVia`, which suppresses on any
        // coincident pin regardless of layer and so misses an orphan via that
        // lands on a pin of the wrong layer — exactly the case here.

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
                    b: placedPins[i].position,
                    layerA: anchor.layer,
                    layerB: placedPins[i].layer
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
                b: placedPins[pair.j].position,
                layerA: placedPins[pair.i].layer,
                layerB: placedPins[pair.j].layer
            ))
        }
        return edges
    }
}
