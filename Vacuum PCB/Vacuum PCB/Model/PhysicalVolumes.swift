import Foundation

// Physical-volume decomposition, shared by the `vacuum-cli continuity --volumes`
// command and the 3D preview's volume highlighter.
//
// A *volume* is one sealed air cavity inside a single plate, the way it exists
// before the two plates are bonded with silicone. It's the natural unit for
// bench-testing a freshly printed plate: plug every hole but one, pull vacuum
// on the last, and a perfect vacuum proves that cavity is fully connected and
// leak-free.
//
// This is NOT the same as a net. A net is the logical connection; a volume is
// physical and plate-local. They differ wherever a net crosses the silicone:
//   • a net living on one plate  → one volume (matches the net)
//   • a net crossing both plates → two (or more) volumes, one per plate,
//     joined only at the through-holes — which aren't connected yet.
//
// Connectivity mirrors `Ratsnest`/`PlateBuilder` exactly so it matches what
// actually prints: a route segment's waypoints are extended to snap to nearby
// pins on the same layer (a route reaches a pad through its bore, not at an
// exact point), and a via joins layers only where ≥2 meet. The one departure:
// a via that spans both plates is a cross-silicone through-hole — we do NOT
// join the plates through it, so each plate's cavities stand alone. It instead
// surfaces as a "bridge" hole on each plate.

/// Human feature name for a component pin, e.g. "transistor gate".
func continuityFeature(_ comp: Component, pinKey: String) -> String {
    switch comp.kind {
    case .transistor:   return pinKey == "gate" ? "transistor gate" : "transistor source/drain"
    case .resistor:     return "resistor end"
    case .vacuumSource: return "vacuum-source edge bore"
    case .atmVent:      return "vent edge bore"
    case .port:
        switch comp.portDirection {
        case .input:  return "input port edge bore"
        case .output: return "output port edge bore"
        case nil:     return "port edge bore"
        }
    case .led:       return "LED indicator dimple"
    case .connector: return "connector tube (edge)"
    case .subpart:   return "subpart boundary pin"
    case .screw:     return "screw (no pin)"
    }
}

/// One opening of a physical volume — a place you can plug or press a tube on.
struct VolumeHole: Hashable {
    var ref: String        // "Q5.b", "VENT.p", or "via"
    var feature: String    // "transistor source/drain", "via → bottom plate", …
    var layer: Layer
    var pos: Point
    var isBridge: Bool      // true = a through-hole that joins the other plate
}

/// One routed channel run forming part of a volume — the extended waypoint
/// polyline plus its layer, ready to hand to `PlateBuilder.volumeMesh`.
struct VolumeSegment: Hashable {
    var positions: [Point]
    var layer: Layer
}

/// One sealed air cavity in a single plate.
struct Volume: Identifiable, Hashable {
    /// Stable, human-facing id assigned in display order: `T1`…`Tn` for the top
    /// plate, `B1`…`Bn` for the bottom.
    var id: String
    var plate: Plate
    var netLabel: String
    var holes: [VolumeHole]
    /// The channel runs that make up this cavity (for building its 3D mesh).
    var segments: [VolumeSegment]
}

/// Decompose a (flattened) document into per-plate physical volumes.
func physicalVolumes(_ doc: CircuitDocument) -> [Volume] {
    let m = doc.manufacturing
    let snaps = doc.librarySnapshots
    let compById = Dictionary(doc.logic.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let placeById = Dictionary(doc.physical.placements.map { ($0.componentId, $0) }, uniquingKeysWith: { a, _ in a })
    let netLabelById = Dictionary(doc.logic.nets.map { ($0.id, $0.label) }, uniquingKeysWith: { a, _ in a })
    let eps = 0.05
    // Same tolerance the CAD pipeline uses to attach a channel end to a pin.
    let pinSnapTol = m.dimpleDiameter / 2 + 0.5

    // One board-wide node graph. Each node is tagged with the net that created
    // it, so the within-net bore-overlap heal below can't fuse two *different*
    // nets that merely route within a clearance of each other. Cross-net joins
    // happen only through real open channels — resistors (see below). Vias join
    // depths within a plate; cross-silicone vias are cut (each side becomes a
    // bridge hole). Transistors do NOT join their pins: source/drain are gated
    // by the silicone membrane, not an open channel, so they never merge.
    struct GNode { let net: UUID; let layer: Layer; let p: Point }
    var nodes: [GNode] = []
    var parent: [Int] = []
    func nodeIndex(_ net: UUID, _ layer: Layer, _ p: Point) -> Int {
        for (i, q) in nodes.enumerated() where q.net == net && q.layer == layer
            && abs(q.p.x - p.x) < eps && abs(q.p.y - p.y) < eps { return i }
        nodes.append(GNode(net: net, layer: layer, p: p))
        parent.append(parent.count)
        return nodes.count - 1
    }
    func find(_ x: Int) -> Int { var c = x; while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }; return c }
    func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }

    struct PendingHole { let node: Int; let hole: VolumeHole }
    var pendingHoles: [PendingHole] = []
    var pendingSegs: [(node: Int, seg: VolumeSegment)] = []
    var pinNodeByRef: [PinRef: Int] = [:]

    for net in doc.logic.nets {
        struct PlacedPin { let ref: String; let feature: String; let layer: Layer; let pos: Point; let pinRef: PinRef }
        var placedPins: [PlacedPin] = []
        var pinsByLayer: [Layer: [Point]] = [:]
        for pinRef in net.pins {
            guard let comp = compById[pinRef.componentId],
                  let place = placeById[pinRef.componentId],
                  let fpPin = comp.footprint(m, snapshots: snaps).pin(pinRef.pinKey) else { continue }
            let layer = place.resolvedLayer(of: fpPin, on: comp)
            let pos = place.worldPosition(of: fpPin)
            let pinName = comp.kind == .connector ? comp.connectorPinName(pinRef.pinKey) : pinRef.pinKey
            placedPins.append(PlacedPin(ref: "\(comp.label).\(pinName)",
                                        feature: continuityFeature(comp, pinKey: pinRef.pinKey),
                                        layer: layer, pos: pos, pinRef: pinRef))
            pinsByLayer[layer, default: []].append(pos)
        }
        for pin in placedPins {
            let n = nodeIndex(net.id, pin.layer, pin.pos)
            pinNodeByRef[pin.pinRef] = n
            pendingHoles.append(PendingHole(node: n,
                hole: VolumeHole(ref: pin.ref, feature: pin.feature, layer: pin.layer, pos: pin.pos, isBridge: false)))
        }

        // Routes: union extended waypoints along each segment; remember the
        // extended polyline so the volume's mesh can be rebuilt later.
        for route in doc.physical.routes where route.netId == net.id {
            for segment in route.segments {
                let positions = PlateBuilder.extendedWaypointPositions(
                    for: segment, pinsOnLayer: pinsByLayer[segment.layer] ?? [], tolerance: pinSnapTol)
                guard positions.count >= 2 else { continue }
                let idxs = positions.map { nodeIndex(net.id, segment.layer, $0) }
                for i in 0..<(idxs.count - 1) { union(idxs[i], idxs[i + 1]) }
                pendingSegs.append((node: idxs[0], seg: VolumeSegment(positions: positions, layer: segment.layer)))
            }
        }

        // Vias: join depths within a plate; cut across the silicone (record a
        // bridge hole on each plate instead).
        for group in doc.physical.viaLayerGroups(netId: net.id) where group.layers.count >= 2 {
            let platesPresent = Set(group.layers.map { $0.plate })
            for plate in platesPresent {
                let layerNodes = group.layers.filter { $0.plate == plate }.map { nodeIndex(net.id, $0, group.position) }
                for k in layerNodes.dropFirst() { union(layerNodes[0], k) }
                if platesPresent.count >= 2, let n0 = layerNodes.first {
                    pendingHoles.append(PendingHole(node: n0,
                        hole: VolumeHole(ref: "via", feature: "via → \(plate.opposite == .top ? "top" : "bottom") plate",
                                         layer: nodes[n0].layer, pos: group.position, isBridge: true)))
                }
            }
        }
    }

    // Heal sub-bore gaps: two same-net, same-layer channel points whose round
    // bores overlap (centres within one channelDiameter) are physically one
    // cavity. This stitches across a subpart boundary, where the parent and
    // child channels meet end-to-end but the boundary pin they'd both snap to
    // was dropped during flatten. Restricted to the same net so it can't fuse
    // two distinct nets that merely route a clearance apart.
    let mergeDist = m.channelDiameter
    for i in 0..<nodes.count {
        for j in (i + 1)..<nodes.count where nodes[i].net == nodes[j].net && nodes[i].layer == nodes[j].layer {
            let dx = nodes[i].p.x - nodes[j].p.x, dy = nodes[i].p.y - nodes[j].p.y
            if dx * dx + dy * dy < mergeDist * mergeDist { union(i, j) }
        }
    }

    // Resistors are open serpentine channels joining their two (same-plate)
    // pins, so they merge the two cavities those pins sit in: on the bench a
    // vacuum on one side bleeds through to the other, so a "perfect vacuum"
    // test has to plug both. (Transistors are deliberately NOT joined.)
    for comp in doc.logic.components where comp.kind == .resistor {
        if let a = pinNodeByRef[PinRef(componentId: comp.id, pinKey: "1")],
           let b = pinNodeByRef[PinRef(componentId: comp.id, pinKey: "2")] {
            union(a, b)
        }
    }

    // Group holes, bridges and segments by connected component.
    var holesByRoot: [Int: [VolumeHole]] = [:]
    var segsByRoot: [Int: [VolumeSegment]] = [:]
    var netsByRoot: [Int: Set<String>] = [:]
    for ph in pendingHoles {
        let root = find(ph.node)
        holesByRoot[root, default: []].append(ph.hole)
        netsByRoot[root, default: []].insert(netLabelById[nodes[ph.node].net] ?? "?")
    }
    for ps in pendingSegs {
        segsByRoot[find(ps.node), default: []].append(ps.seg)
    }

    // Built without ids; ids are assigned after the final sort below.
    struct RawVolume { var plate: Plate; var netLabel: String; var holes: [VolumeHole]; var segments: [VolumeSegment] }
    var raw: [RawVolume] = []
    for (root, holes) in holesByRoot {
        let plate = holes.first!.layer.plate
        let sortedHoles = holes.sorted {
            ($0.layer.depth, $0.pos.x, $0.pos.y) < ($1.layer.depth, $1.pos.x, $1.pos.y)
        }
        // A resistor-merged cavity spans several nets; name it compactly.
        let labels = (netsByRoot[root] ?? []).sorted()
        let label: String
        switch labels.count {
        case 0:    label = "?"
        case 1, 2: label = labels.joined(separator: " / ")
        default:   label = "\(labels.prefix(2).joined(separator: " / ")) +\(labels.count - 2)"
        }
        raw.append(RawVolume(plate: plate, netLabel: label, holes: sortedHoles, segments: segsByRoot[root] ?? []))
    }

    // Top plate first, then by net label, then by where the cavity sits.
    let sorted = raw.sorted {
        if $0.plate != $1.plate { return $0.plate == .top }
        if $0.netLabel != $1.netLabel { return $0.netLabel < $1.netLabel }
        return ($0.holes.first?.pos.y ?? 0, $0.holes.first?.pos.x ?? 0)
             < ($1.holes.first?.pos.y ?? 0, $1.holes.first?.pos.x ?? 0)
    }

    var topN = 0, bottomN = 0
    return sorted.map { r in
        let id: String
        if r.plate == .top { topN += 1; id = "T\(topN)" } else { bottomN += 1; id = "B\(bottomN)" }
        return Volume(id: id, plate: r.plate, netLabel: r.netLabel, holes: r.holes, segments: r.segments)
    }
}
