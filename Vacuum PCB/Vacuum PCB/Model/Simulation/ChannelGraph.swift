import Foundation
import CryptoKit

/// Routed-channel subdivision for the simulator.
///
/// The base network model is one zero-resistance node per net: a channel
/// contributes volume but never drops pressure, so a rail delivered through
/// half a metre of thin supply run reads the same at both ends. Real printed
/// boards disagree — bench measurements show the supply run and long bus legs
/// eating most of the available vacuum. This graph splits each net that has
/// routed geometry into sub-nodes joined by finite spans so that, when
/// `SimulationParameters.channelResistancePerMm > 0`, flow along a channel
/// costs pressure in proportion to its routed length.
///
/// Construction mirrors `Ratsnest.missingEdges` vertex-for-vertex — the same
/// (layer, XY) keying, the same `PlateBuilder.extendedWaypointPositions`
/// pin-snap, the same ≥2-layer via rule — so "connected" means the same thing
/// to the resistive graph as it does to the ratsnest and DRC.
///
/// Behavioural guarantees:
///   * `channelResistancePerMm == 0` (the default): the engine ignores the
///     graph entirely and solves one node per net — bit-for-bit the
///     historical behaviour.
///   * Pins that don't land on any routed vertex (unplaced components,
///     unrouted or partially-routed nets, schematic-stage documents) attach
///     to the net's hub node, and disconnected route islands are tied to the
///     hub with zero-length stiff spans — a net never falls apart just
///     because its routing is unfinished.
///   * The hub node keeps the original net id, so every existing per-net
///     reader (schematic heatmap, net list, carried-forward pressures) keeps
///     working unchanged.
struct ChannelGraph {
    /// One straight run of channel between two solver nodes. `lengthMm == 0`
    /// marks a stiff tie (island bridging, via bores) — the engine clamps the
    /// length before dividing so ties are very conductive, not infinite.
    struct Span {
        let node1: UUID
        let node2: UUID
        let lengthMm: Double
    }

    /// Synthetic sub-nodes (every routed-net vertex beyond the hub), as `Net`
    /// values so the engine can index them alongside the real nets.
    let subNodes: [Net]
    let spans: [Span]
    /// Solver node for each device pin when subdivision is on. Missing key =
    /// attach at the pin's net hub (the original net id).
    let nodeByPin: [PinRef: UUID]
    /// Distributed capacitance per solver node when subdivision is on. Covers
    /// every node: sub-nodes, subdivided hubs, and untouched single-node nets.
    let capacitanceByNode: [UUID: Double]
    /// Fraction of its net's global leak each node carries (proportional to
    /// its share of the net's volume), so subdividing a net doesn't multiply
    /// the net's total leak to atmosphere. 1.0 for single-node nets.
    let leakShareByNode: [UUID: Double]
    /// Hub (original net id) per sub-node. When subdivision is off the engine
    /// mirrors hub pressures onto sub-nodes so node-addressed readers (probes)
    /// stay valid in both modes.
    let hubBySubNode: [UUID: UUID]

    static let empty = ChannelGraph(subNodes: [], spans: [], nodeByPin: [:],
                                    capacitanceByNode: [:], leakShareByNode: [:],
                                    hubBySubNode: [:])

    var isEmpty: Bool { subNodes.isEmpty && spans.isEmpty }

    /// Deterministic sub-node UUID: SHA-256 of "chan:netId:index" with the
    /// UUID version/variant bits forced. Stable across rebuilds of the same
    /// document so carried-forward pressures and CLI runs are reproducible.
    static func subNodeId(net: UUID, index: Int) -> UUID {
        let digest = SHA256.hash(data: Data("chan:\(net.uuidString):\(index)".utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Builds the subdivision for a *flattened* document (the same one
    /// `PneumaticNetwork.build` consumes). `netIdRemap` resolves pre-merge
    /// net ids (test points store those) to canonical flattened ids.
    static func build(doc: CircuitDocument, netIdRemap: [UUID: UUID]) -> ChannelGraph {
        let eps = 0.05                                   // ratsnest vertex tolerance
        let pinSnapTol = doc.manufacturing.dimpleDiameter / 2 + 0.5
        let capPerMm = SimulationParameters.defaults.channelCapacitancePerMm
        let pinBaseCap = SimulationParameters.defaults.nodeBaseCapacitance
        let capFloor = 0.02

        var subNodes: [Net] = []
        var spans: [Span] = []
        var nodeByPin: [PinRef: UUID] = [:]
        var capacitanceByNode: [UUID: Double] = [:]
        var leakShareByNode: [UUID: Double] = [:]
        var hubBySubNode: [UUID: UUID] = [:]

        // Canonical net id → test points riding it (tap positions resolved
        // against the live segment geometry, like the CAD bore).
        var tapsByNet: [UUID: [TestPoint]] = [:]
        for tp in doc.physical.testPoints {
            let canonical = netIdRemap[tp.netId] ?? tp.netId
            tapsByNet[canonical, default: []].append(tp)
        }

        for net in doc.logic.nets {
            let routes = doc.physical.routes.filter { $0.netId == net.id }
            if routes.isEmpty {
                // Single-node net: keep the legacy lumped capacitance.
                let cap = max(0.1, Double(net.pins.count) * pinBaseCap)
                capacitanceByNode[net.id] = cap
                leakShareByNode[net.id] = 1.0
                continue
            }

            // ── 1. Vertices + raw spans from the routed polylines ──────────
            struct Vertex { let layer: Layer; var p: Point }
            struct RawSpan { let i: Int; let j: Int; let length: Double; let layer: Layer }
            var vertices: [Vertex] = []
            var rawSpans: [RawSpan] = []

            func vertexIndex(_ layer: Layer, _ p: Point) -> Int {
                for (i, q) in vertices.enumerated()
                where q.layer == layer && abs(q.p.x - p.x) < eps && abs(q.p.y - p.y) < eps {
                    return i
                }
                vertices.append(Vertex(layer: layer, p: p))
                return vertices.count - 1
            }
            func existingVertex(_ layer: Layer, _ p: Point, within tol: Double) -> Int? {
                var best: (i: Int, d: Double)?
                for (i, q) in vertices.enumerated() where q.layer == layer {
                    let d = hypot(q.p.x - p.x, q.p.y - p.y)
                    if d < tol, d < (best?.d ?? .infinity) { best = (i, d) }
                }
                return best?.i
            }

            // Pin world positions feed the same endpoint extension the CAD
            // and ratsnest pipelines use, so a route ending near a pad still
            // meets the pin's vertex.
            struct PlacedPin { let ref: PinRef; let position: Point; let layer: Layer }
            var placedPins: [PlacedPin] = []
            var netPinsByLayer: [Layer: [Point]] = [:]
            for pinRef in net.pins {
                guard let placement = doc.physical.placements.first(where: { $0.componentId == pinRef.componentId }),
                      let component = doc.logic.components.first(where: { $0.id == pinRef.componentId }),
                      let fpPin = component.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pin(pinRef.pinKey)
                else { continue }
                let world = placement.worldPosition(of: fpPin)
                let layer = placement.resolvedLayer(of: fpPin, on: component)
                placedPins.append(PlacedPin(ref: pinRef, position: world, layer: layer))
                netPinsByLayer[layer, default: []].append(world)
            }

            for route in routes {
                for segment in route.segments {
                    let positions = PlateBuilder.extendedWaypointPositions(
                        for: segment,
                        pinsOnLayer: netPinsByLayer[segment.layer] ?? [],
                        tolerance: pinSnapTol
                    )
                    guard positions.count >= 2 else { continue }
                    let indices = positions.map { vertexIndex(segment.layer, $0) }
                    for k in 0..<(indices.count - 1) where indices[k] != indices[k + 1] {
                        let a = positions[k], b = positions[k + 1]
                        rawSpans.append(RawSpan(i: indices[k], j: indices[k + 1],
                                                length: hypot(b.x - a.x, b.y - a.y),
                                                layer: segment.layer))
                    }
                }
            }
            guard !vertices.isEmpty else {
                let cap = max(0.1, Double(net.pins.count) * pinBaseCap)
                capacitanceByNode[net.id] = cap
                leakShareByNode[net.id] = 1.0
                continue
            }

            // Vias: a real via (`.via` marker on ≥2 layers) bores through the
            // plates — short and wide relative to a run, so a zero-length tie.
            // Layers sort deterministically so sub-node ids are stable across
            // rebuilds (`Set` iteration order isn't).
            for group in doc.physical.viaLayerGroups(netId: net.id) where group.layers.count >= 2 {
                let orderedLayers = group.layers.sorted {
                    ($0.plate.rawValue, $0.depth) < ($1.plate.rawValue, $1.depth)
                }
                let nodes = orderedLayers.map { vertexIndex($0, group.position) }
                for k in nodes.dropFirst() where k != nodes[0] {
                    rawSpans.append(RawSpan(i: nodes[0], j: k, length: 0, layer: orderedLayers[0]))
                }
            }

            // ── 2. Test-point taps: split the span they ride ────────────────
            var tapVertexByTestPoint: [UUID: Int] = [:]
            for tp in tapsByNet[net.id] ?? [] {
                let world = doc.physical.testPointWorld(tp) ?? tp.position
                let layer = Layer(plate: tp.plate, depth: tp.depth)
                var best: (spanIdx: Int, t: Double, d: Double, proj: Point)?
                for (si, s) in rawSpans.enumerated()
                where s.layer == layer && s.length > eps {
                    let a = vertices[s.i].p, b = vertices[s.j].p
                    let dx = b.x - a.x, dy = b.y - a.y
                    let lenSq = dx * dx + dy * dy
                    guard lenSq > 0 else { continue }
                    let t = max(0, min(1, ((world.x - a.x) * dx + (world.y - a.y) * dy) / lenSq))
                    let proj = Point(x: a.x + t * dx, y: a.y + t * dy)
                    let d = hypot(world.x - proj.x, world.y - proj.y)
                    if d < 0.75, d < (best?.d ?? .infinity) { best = (si, t, d, proj) }
                }
                if let hit = best {
                    let s = rawSpans[hit.spanIdx]
                    if hit.t * s.length < eps {
                        tapVertexByTestPoint[tp.id] = s.i
                    } else if (1 - hit.t) * s.length < eps {
                        tapVertexByTestPoint[tp.id] = s.j
                    } else {
                        vertices.append(Vertex(layer: layer, p: hit.proj))
                        let v = vertices.count - 1
                        rawSpans.append(RawSpan(i: s.i, j: v, length: s.length * hit.t, layer: s.layer))
                        rawSpans.append(RawSpan(i: v, j: s.j, length: s.length * (1 - hit.t), layer: s.layer))
                        rawSpans.remove(at: hit.spanIdx)
                        tapVertexByTestPoint[tp.id] = v
                    }
                } else if let near = existingVertex(layer, world, within: 0.75) {
                    tapVertexByTestPoint[tp.id] = near
                }
                // else: fall through — the probe reads the hub like today.
            }

            // ── 3. Resolve pin attachments (before contraction, so their
            //      vertices are protected from being merged away) ────────────
            var pinVertexByRef: [PinRef: Int] = [:]
            var hubExtraCap = 0.0
            for pin in placedPins {
                if let v = existingVertex(pin.layer, pin.position, within: eps) {
                    pinVertexByRef[pin.ref] = v
                } else {
                    hubExtraCap += pinBaseCap  // unrouted / off-route pin → hub
                }
            }
            // Pins with no placement/footprint never entered placedPins; their
            // base volume still belongs to the net — park it on the hub.
            hubExtraCap += Double(max(0, net.pins.count - placedPins.count)) * pinBaseCap

            // ── 4. Bridge disconnected islands to the hub ───────────────────
            var parent = Array(0..<vertices.count)
            func find(_ x: Int) -> Int {
                var c = x
                while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }
                return c
            }
            for s in rawSpans {
                let a = find(s.i), b = find(s.j)
                if a != b { parent[a] = b }
            }
            let hubRoot = find(0)
            var bridgedRoots = Set<Int>()
            for v in vertices.indices {
                let r = find(v)
                if r != hubRoot, !bridgedRoots.contains(r) {
                    bridgedRoots.insert(r)
                    rawSpans.append(RawSpan(i: 0, j: v, length: 0, layer: vertices[0].layer))
                }
            }

            // ── 5. Contract pass-through vertices. Only pins, taps, the hub,
            //      and real junctions (degree ≠ 2) need to be solver nodes; a
            //      chain of route bends is one channel, so merge its spans.
            //      This is what keeps the matrix small enough to stay
            //      interactive — every waypoint as a node roughly triples N.
            var protected = Set<Int>([0])
            protected.formUnion(pinVertexByRef.values)
            protected.formUnion(tapVertexByTestPoint.values)

            var adjacency: [[Int]] = Array(repeating: [], count: vertices.count)  // span indices
            for (si, s) in rawSpans.enumerated() where s.i != s.j {
                adjacency[s.i].append(si)
                adjacency[s.j].append(si)
            }
            var spanAlive = [Bool](repeating: true, count: rawSpans.count)
            var vertexAlive = [Bool](repeating: true, count: vertices.count)
            for v in vertices.indices where !protected.contains(v) {
                let incident = adjacency[v].filter { spanAlive[$0] }
                if incident.isEmpty {
                    vertexAlive[v] = false                    // decorative stub end
                    continue
                }
                guard incident.count == 2 else { continue }
                let s1 = rawSpans[incident[0]], s2 = rawSpans[incident[1]]
                let a = s1.i == v ? s1.j : s1.i
                let b = s2.i == v ? s2.j : s2.i
                guard a != v, b != v else { continue }        // self-loop guard
                spanAlive[incident[0]] = false
                spanAlive[incident[1]] = false
                vertexAlive[v] = false
                let merged = RawSpan(i: a, j: b, length: s1.length + s2.length, layer: s1.layer)
                rawSpans.append(merged)
                spanAlive.append(true)
                let si = rawSpans.count - 1
                adjacency[a].append(si)
                adjacency[b].append(si)
            }

            // ── 6. Mint node ids (deterministic by surviving vertex index):
            //      vertex 0 is the hub and keeps the original net id ─────────
            var nodeId = [UUID?](repeating: nil, count: vertices.count)
            for v in vertices.indices where vertexAlive[v] {
                if v == 0 {
                    nodeId[v] = net.id
                } else {
                    let id = subNodeId(net: net.id, index: v)
                    nodeId[v] = id
                    subNodes.append(Net(id: id, label: "\(net.label)·\(v)", pins: []))
                    hubBySubNode[id] = net.id
                }
            }
            var caps = [Double](repeating: 0, count: vertices.count)
            for (si, s) in rawSpans.enumerated()
            where spanAlive[si] && s.i != s.j && vertexAlive[s.i] && vertexAlive[s.j] {
                spans.append(Span(node1: nodeId[s.i]!, node2: nodeId[s.j]!, lengthMm: s.length))
                caps[s.i] += s.length * capPerMm / 2
                caps[s.j] += s.length * capPerMm / 2
            }

            // ── 7. Publish attachments + distribute capacitance ─────────────
            for (ref, v) in pinVertexByRef {
                nodeByPin[ref] = nodeId[v]!
                caps[v] += pinBaseCap
            }
            for (tpId, v) in tapVertexByTestPoint {
                nodeByPin[PinRef(componentId: tpId, pinKey: "tap")] = nodeId[v]!
            }
            caps[0] += hubExtraCap

            var total = 0.0
            for v in vertices.indices where vertexAlive[v] {
                caps[v] = max(capFloor, caps[v])
                total += caps[v]
            }
            for v in vertices.indices where vertexAlive[v] {
                capacitanceByNode[nodeId[v]!] = caps[v]
                leakShareByNode[nodeId[v]!] = total > 0 ? caps[v] / total : 1.0
            }
        }

        return ChannelGraph(subNodes: subNodes, spans: spans, nodeByPin: nodeByPin,
                            capacitanceByNode: capacitanceByNode,
                            leakShareByNode: leakShareByNode,
                            hubBySubNode: hubBySubNode)
    }
}
