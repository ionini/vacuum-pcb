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
// Connectivity mirrors `PlateBuilder` exactly so it matches what actually
// prints: a route segment's waypoints are extended to snap to nearby
// transistor source/drain pins on the same layer (the only pins the CAD
// pipeline extends channels toward — `collectPinPositions`), any two same-net
// bores within one channel diameter fuse (overlapping voids in CSG), and a
// via joins layers only where ≥2 meet. Note this is deliberately *stricter*
// than `Ratsnest`/DRC's logical union-find, whose pin-snap tolerance is a
// dimple radius: a route can pass ratsnest yet print short — that split is
// exactly what DRC's sealed-cavity pass reads off these volumes. The one departure:
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
    case .connector: return (comp.connectorDebugPorts ?? false)
        ? "connector debug port edge bore"
        : "connector tube (edge)"
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
    /// Owning net — lets the collision check ignore a net overlapping itself.
    var net: UUID
}

/// A resistor whose serpentine channel is part of a volume (it joins the
/// volume's two halves). Carries just enough pose to rebuild the serpentine.
struct VolumeResistor: Hashable {
    var position: Point
    var rotation: Rotation
    var layer: Layer
    var size: ResistorSize
}

/// A same-plate via inside a volume — a vertical bore joining channel depths
/// (e.g. T0↔T1). Cross-silicone vias are NOT here; they're bridge `VolumeHole`s.
struct VolumeVia: Hashable {
    var pos: Point
    var layers: [Layer]
    var net: UUID
}

/// A testing point inside a volume — the vertical tapered bore from a tapped
/// channel's midline (`midZ`) out to the plate's outer face (`outerZ`). Stored
/// with its resolved Z endpoints so the highlight mesh can rebuild the bore
/// without re-deriving plate thicknesses (which `volumeMesh` doesn't receive).
struct VolumeTestPoint: Hashable {
    var pos: Point
    var plate: Plate
    var midZ: Double
    var outerZ: Double
}

/// A transistor/LED *body* cavity belonging to a volume: a source/drain pad or
/// a gate (or LED) dimple. These are the widest features on the board, so they
/// dominate collision-checking, and they're painted into the highlight using
/// the *same* solids the plate builds (so it's a 1:1 match, not a proxy ball).
///
/// We store the placement pose rather than a single point so both the real
/// solid (gate dome / single pad lobe) and the conservative collision sphere
/// can be reconstructed. `component` lets the collision pass skip a transistor's
/// own pad pair (the intended valve gap) while still catching two *different*
/// components' bodies overlapping.
struct VolumeFeature: Hashable {
    enum Kind: String, Hashable { case dimple, ledDimple, pad }
    /// Placement (gate / LED) centre, world coords. A pad lobe is built from
    /// this centre + rotation, exactly as `PlateBuilder` does.
    var center: Point
    var rotation: Rotation
    /// The placement plate (gate / LED dimple plate). Pads sit on `plate.opposite`.
    var plate: Plate
    var component: UUID
    var kind: Kind
    var net: UUID
    /// Cavity radius — used for the conservative collision sphere.
    var radius: Double
    /// World position of this feature's pin: the pad bore (pad) or the gate
    /// centre (dimple). Used as the collision-sphere centre, and to choose which
    /// of the two pad lobes is *this* net's (the one nearest the bore) — robust
    /// to any rotation/flatten, unlike a fixed side mapping.
    var pinPos: Point
}

/// One resistor-free stretch of a volume: the geometry reachable from a point
/// of the cavity *without* passing through a resistor serpentine. A volume
/// with no resistors has exactly one section; a resistor-merged cavity has
/// one per net-side. This is what the 3D preview's secondary click ("highlight
/// up to the resistors") lights, while the primary click lights the whole
/// volume. Resistors belong to no section — they are the boundaries.
struct VolumeSection: Hashable {
    var holes: [VolumeHole]
    var segments: [VolumeSegment]
    var vias: [VolumeVia]
    var features: [VolumeFeature]
    var testPoints: [VolumeTestPoint]
}

/// One sealed air cavity in a single plate.
struct Volume: Identifiable, Hashable {
    /// Stable, human-facing id assigned in display order: `T1`…`Tn` for the top
    /// plate, `B1`…`Bn` for the bottom.
    var id: String
    var plate: Plate
    var netLabel: String
    /// Every net with any geometry in this cavity (≥2 when a resistor joins
    /// nets into one open volume). Lets per-net checks (DRC's sealed-cavity
    /// pass) map a net to the set of cavities it actually prints as.
    var nets: Set<UUID>
    var holes: [VolumeHole]
    /// Geometry that makes up this cavity (for building its 3D highlight mesh).
    var segments: [VolumeSegment]
    var resistors: [VolumeResistor]
    var vias: [VolumeVia]
    var features: [VolumeFeature]
    var testPoints: [VolumeTestPoint]
    /// The cavity split at its resistors (see `VolumeSection`). Partitions
    /// `holes` / `segments` / `vias` / `features` / `testPoints`; `resistors`
    /// belong to none of them.
    var sections: [VolumeSection] = []

    // MARK: Highlight / pick ids

    /// Separator between a volume id and a section key in a highlight id.
    static let sectionSeparator: Character = "#"
    /// Section key of the resistors-only pick node.
    static let resistorsSectionKey = "res"

    /// Highlight id of one section of this volume, e.g. `"T3#1"`. Every scene
    /// pick node carries one of these; a plain volume id (`"T3"`) in the
    /// highlight set lights all of them.
    func sectionID(_ index: Int) -> String { "\(id)\(Self.sectionSeparator)\(index)" }
    /// Highlight id of this volume's resistor serpentines, e.g. `"T3#res"`.
    var resistorsID: String { "\(id)\(Self.sectionSeparator)\(Self.resistorsSectionKey)" }

    /// The volume part of a highlight id: `"T3#1"` → `"T3"`, `"T3"` → `"T3"`.
    static func volumeID(fromHighlightID hid: String) -> String {
        if let cut = hid.firstIndex(of: sectionSeparator) { return String(hid[..<cut]) }
        return hid
    }
    /// The section part of a highlight id, or nil for a whole-volume id.
    static func sectionKey(fromHighlightID hid: String) -> String? {
        guard let cut = hid.firstIndex(of: sectionSeparator) else { return nil }
        return String(hid[hid.index(after: cut)...])
    }
    /// The plate a volume id belongs to, read off its `T`/`B` prefix.
    static func plate(ofVolumeID vid: String) -> Plate? {
        switch vid.first {
        case "T": return .top
        case "B": return .bottom
        default:  return nil
        }
    }

    /// A render-only `Volume` holding just one section's geometry (no
    /// resistors) — what `PlateBuilder.volumeMesh` turns into that section's
    /// pick/highlight node.
    func sectionVolume(_ index: Int) -> Volume {
        let sec = sections[index]
        return Volume(id: sectionID(index), plate: plate, netLabel: netLabel, nets: nets,
                      holes: sec.holes, segments: sec.segments, resistors: [], vias: sec.vias,
                      features: sec.features, testPoints: sec.testPoints)
    }
    /// A render-only `Volume` holding just the resistor serpentines.
    var resistorsVolume: Volume {
        Volume(id: resistorsID, plate: plate, netLabel: netLabel, nets: nets,
               holes: [], segments: [], resistors: resistors, vias: [], features: [], testPoints: [])
    }
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
    // Outer-face Z per plate — where a test-point bore's mouth opens.
    let topOuterZ = m.siliconeThickness / 2 + m.plateThickness(forLayerCount: doc.physical.topLayers)
    let bottomOuterZ = -m.siliconeThickness / 2 - m.plateThickness(forLayerCount: doc.physical.bottomLayers)

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
    var pendingVias: [(node: Int, via: VolumeVia)] = []
    var pendingResistors: [(node: Int, res: VolumeResistor)] = []
    var pendingFeatures: [(node: Int, feature: VolumeFeature)] = []
    var pendingTestPoints: [(node: Int, tp: VolumeTestPoint)] = []
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
            // Channel-end extension targets — transistor source/drain pads
            // ONLY, mirroring `PlateBuilder.collectPinPositions`: the printed
            // channel is extended toward a drifted pad bore, but never toward
            // a port / vent / source pin. Every other junction has to earn
            // its connectivity from real bore overlap (the channel-diameter
            // heal below), or the model would call cavities joined that the
            // print leaves 2 mm apart (the Incrementor 4bit vent-tap case).
            if comp.kind == .transistor, pinRef.pinKey == "a" || pinRef.pinKey == "b" {
                pinsByLayer[layer, default: []].append(pos)
            }
        }
        for pin in placedPins {
            let n = nodeIndex(net.id, pin.layer, pin.pos)
            pinNodeByRef[pin.pinRef] = n
            pendingHoles.append(PendingHole(node: n,
                hole: VolumeHole(ref: pin.ref, feature: pin.feature, layer: pin.layer, pos: pin.pos, isBridge: false)))
            // Transistor / LED body cavities (gate or LED dimple, source/drain
            // pads) — the widest features, so collision-checking needs them, and
            // the highlight paints them with the real solids.
            if let comp = compById[pin.pinRef.componentId], let place = placeById[pin.pinRef.componentId] {
                switch comp.kind {
                case .transistor where pin.pinRef.pinKey == "gate":
                    pendingFeatures.append((node: n, feature: VolumeFeature(
                        center: place.position, rotation: place.rotation, plate: place.layer,
                        component: comp.id, kind: .dimple, net: net.id, radius: m.dimpleDiameter / 2, pinPos: pin.pos)))
                case .transistor:
                    pendingFeatures.append((node: n, feature: VolumeFeature(
                        center: place.position, rotation: place.rotation, plate: place.layer,
                        component: comp.id, kind: .pad, net: net.id, radius: m.padsDiameter / 2, pinPos: pin.pos)))
                case .led:
                    pendingFeatures.append((node: n, feature: VolumeFeature(
                        center: place.position, rotation: place.rotation, plate: place.layer,
                        component: comp.id, kind: .ledDimple, net: net.id, radius: m.ledDimpleDiameter / 2, pinPos: pin.pos)))
                default: break
                }
            }
        }

        // Routes: union extended waypoints along each segment; remember the
        // extended polyline so the volume's mesh can be rebuilt later.
        for route in doc.physical.routes where route.netId == net.id {
            for (segIdx, segment) in route.segments.enumerated() {
                let positions = PlateBuilder.extendedWaypointPositions(
                    for: segment, pinsOnLayer: pinsByLayer[segment.layer] ?? [], tolerance: pinSnapTol)
                guard positions.count >= 2 else { continue }
                let idxs = positions.map { nodeIndex(net.id, segment.layer, $0) }
                for i in 0..<(idxs.count - 1) { union(idxs[i], idxs[i + 1]) }
                pendingSegs.append((node: idxs[0], seg: VolumeSegment(positions: positions, layer: segment.layer, net: net.id)))

                // Testing points riding this segment join its cavity, so the 3D
                // preview selects/highlights them with the net and paints the
                // vertical bore into the highlight mesh. `midZ` uses the point's
                // own (F-cycled) depth; the bore runs out to the plate face.
                for tp in doc.physical.testPoints where tp.netId == net.id && tp.segmentIndex == segIdx {
                    let tpWorld = segment.point(atOffset: tp.offset)
                    let tn = nodeIndex(net.id, segment.layer, tpWorld)
                    union(tn, idxs[0])
                    pendingTestPoints.append((node: tn, tp: VolumeTestPoint(
                        pos: tpWorld, plate: tp.plate,
                        midZ: m.midZ(for: Layer(plate: tp.plate, depth: tp.depth)),
                        outerZ: tp.plate == .top ? topOuterZ : bottomOuterZ)))
                }
            }
        }

        // Vias: join depths within a plate; cut across the silicone (record a
        // bridge hole on each plate instead).
        for group in doc.physical.viaLayerGroups(netId: net.id) where group.layers.count >= 2 {
            let platesPresent = Set(group.layers.map { $0.plate })
            for plate in platesPresent {
                let layersOnPlate = Array(group.layers.filter { $0.plate == plate })
                let layerNodes = layersOnPlate.map { nodeIndex(net.id, $0, group.position) }
                for k in layerNodes.dropFirst() { union(layerNodes[0], k) }
                guard let n0 = layerNodes.first else { continue }
                if platesPresent.count >= 2 {
                    // Cross-silicone: a bridge hole (mate through it later).
                    pendingHoles.append(PendingHole(node: n0,
                        hole: VolumeHole(ref: "via", feature: "via → \(plate.opposite == .top ? "top" : "bottom") plate",
                                         layer: nodes[n0].layer, pos: group.position, isBridge: true)))
                }
                if layersOnPlate.count >= 2 {
                    // Same-plate via: a vertical bore joining channel depths —
                    // real geometry to paint into the highlight.
                    pendingVias.append((node: n0, via: VolumeVia(pos: group.position, layers: layersOnPlate, net: net.id)))
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

    // Merge same-net channels that physically overlap *mid-span*: two channels
    // of one net can cross at a point that's a waypoint of neither, so the node
    // heal above misses them and the net gets split into separate volumes (e.g.
    // a VAC rail whose distribution channel crosses each sub-block's tap). Same
    // net + same layer + bores overlapping ⇒ one cavity. Same-net only, so it
    // can't fuse distinct nets; a non-overlapping same-net gap (a real break)
    // stays split.
    func segDist2D(_ a0: Point, _ a1: Point, _ b0: Point, _ b1: Point) -> Double {
        func clamp(_ x: Double) -> Double { x < 0 ? 0 : (x > 1 ? 1 : x) }
        let d1x = a1.x - a0.x, d1y = a1.y - a0.y
        let d2x = b1.x - b0.x, d2y = b1.y - b0.y
        let rx = a0.x - b0.x, ry = a0.y - b0.y
        let aa = d1x * d1x + d1y * d1y, ee = d2x * d2x + d2y * d2y, ff = d2x * rx + d2y * ry
        let eps = 1e-9
        var s = 0.0, t = 0.0
        if aa <= eps && ee <= eps { return (rx * rx + ry * ry).squareRoot() }
        if aa <= eps { t = clamp(ff / ee) }
        else {
            let cc = d1x * rx + d1y * ry
            if ee <= eps { s = clamp(-cc / aa) }
            else {
                let bb = d1x * d2x + d1y * d2y
                let denom = aa * ee - bb * bb
                s = denom > eps ? clamp((bb * ff - cc * ee) / denom) : 0
                t = (bb * s + ff) / ee
                if t < 0 { t = 0; s = clamp(-cc / aa) }
                else if t > 1 { t = 1; s = clamp((bb - cc) / aa) }
            }
        }
        let cx = (a0.x + d1x * s) - (b0.x + d2x * t)
        let cy = (a0.y + d1y * s) - (b0.y + d2y * t)
        return (cx * cx + cy * cy).squareRoot()
    }
    // Per-segment XY bounding box (inflated by mergeDist) for broad-phase reject.
    let segBoxes: [(minX: Double, minY: Double, maxX: Double, maxY: Double)] = pendingSegs.map {
        var loX = Double.greatestFiniteMagnitude, loY = loX
        var hiX = -Double.greatestFiniteMagnitude, hiY = hiX
        for p in $0.seg.positions { loX = min(loX, p.x); loY = min(loY, p.y); hiX = max(hiX, p.x); hiY = max(hiY, p.y) }
        return (loX, loY, hiX, hiY)
    }
    for i in 0..<pendingSegs.count where pendingSegs[i].seg.positions.count >= 2 {
        let si = pendingSegs[i].seg, bi = segBoxes[i]
        for j in (i + 1)..<pendingSegs.count {
            let sj = pendingSegs[j].seg
            guard sj.positions.count >= 2, si.net == sj.net, si.layer == sj.layer else { continue }
            let bj = segBoxes[j]
            if bi.maxX + mergeDist < bj.minX || bj.maxX + mergeDist < bi.minX
            || bi.maxY + mergeDist < bj.minY || bj.maxY + mergeDist < bi.minY { continue }
            if find(pendingSegs[i].node) == find(pendingSegs[j].node) { continue }
            var overlaps = false
            outer: for u in 0..<(si.positions.count - 1) {
                for v in 0..<(sj.positions.count - 1) {
                    if segDist2D(si.positions[u], si.positions[u + 1], sj.positions[v], sj.positions[v + 1]) < mergeDist {
                        overlaps = true; break outer
                    }
                }
            }
            if overlaps { union(pendingSegs[i].node, pendingSegs[j].node) }
        }
    }

    // Snapshot connectivity *before* the resistor merge: every node's root at
    // this point identifies the resistor-free section it belongs to, which is
    // what the 3D preview's "highlight up to the resistors" pick lights.
    let sectionRoot: [Int] = (0..<nodes.count).map { find($0) }

    // Resistors are open serpentine channels joining their two (same-plate)
    // pins, so they merge the two cavities those pins sit in: on the bench a
    // vacuum on one side bleeds through to the other, so a "perfect vacuum"
    // test has to plug both. (Transistors are deliberately NOT joined.)
    for comp in doc.logic.components where comp.kind == .resistor {
        guard let a = pinNodeByRef[PinRef(componentId: comp.id, pinKey: "1")],
              let b = pinNodeByRef[PinRef(componentId: comp.id, pinKey: "2")],
              let place = placeById[comp.id] else { continue }
        union(a, b)
        pendingResistors.append((node: a, res: VolumeResistor(
            position: place.position, rotation: place.rotation,
            layer: Layer(plate: place.layer, depth: place.depth),
            size: comp.resistorSize ?? .medium)))
    }

    // Group holes, bridges, segments, vias and resistors by connected component.
    var holesByRoot: [Int: [VolumeHole]] = [:]
    var segsByRoot: [Int: [VolumeSegment]] = [:]
    var viasByRoot: [Int: [VolumeVia]] = [:]
    var resByRoot: [Int: [VolumeResistor]] = [:]
    var featuresByRoot: [Int: [VolumeFeature]] = [:]
    var netsByRoot: [Int: Set<String>] = [:]
    var netIdsByRoot: [Int: Set<UUID>] = [:]
    for ph in pendingHoles {
        let root = find(ph.node)
        holesByRoot[root, default: []].append(ph.hole)
        netsByRoot[root, default: []].insert(netLabelById[nodes[ph.node].net] ?? "?")
        netIdsByRoot[root, default: []].insert(nodes[ph.node].net)
    }
    for ps in pendingSegs {
        let root = find(ps.node)
        segsByRoot[root, default: []].append(ps.seg)
        netIdsByRoot[root, default: []].insert(ps.seg.net)
    }
    for pv in pendingVias {
        let root = find(pv.node)
        viasByRoot[root, default: []].append(pv.via)
        netIdsByRoot[root, default: []].insert(pv.via.net)
    }
    for pr in pendingResistors { resByRoot[find(pr.node), default: []].append(pr.res) }
    for pf in pendingFeatures { featuresByRoot[find(pf.node), default: []].append(pf.feature) }
    var tpsByRoot: [Int: [VolumeTestPoint]] = [:]
    for pt in pendingTestPoints { tpsByRoot[find(pt.node), default: []].append(pt.tp) }

    // Per-volume sections: partition each root's members by their
    // pre-resistor root. Keyed by final root, then by section root; section
    // order is fixed by sorting on the section's first hole so ids are stable
    // across rebuilds of an unchanged board.
    var sectionsByRoot: [Int: [Int: VolumeSection]] = [:]
    func withSection(_ node: Int, _ body: (inout VolumeSection) -> Void) {
        let root = find(node), sr = sectionRoot[node]
        var plateSecs = sectionsByRoot[root] ?? [:]
        var sec = plateSecs[sr] ?? VolumeSection(holes: [], segments: [], vias: [], features: [], testPoints: [])
        body(&sec)
        plateSecs[sr] = sec
        sectionsByRoot[root] = plateSecs
    }
    for ph in pendingHoles { withSection(ph.node) { $0.holes.append(ph.hole) } }
    for ps in pendingSegs { withSection(ps.node) { $0.segments.append(ps.seg) } }
    for pv in pendingVias { withSection(pv.node) { $0.vias.append(pv.via) } }
    for pf in pendingFeatures { withSection(pf.node) { $0.features.append(pf.feature) } }
    for pt in pendingTestPoints { withSection(pt.node) { $0.testPoints.append(pt.tp) } }

    // Built without ids; ids are assigned after the final sort below.
    struct RawVolume {
        var plate: Plate; var netLabel: String; var nets: Set<UUID>; var holes: [VolumeHole]
        var segments: [VolumeSegment]; var resistors: [VolumeResistor]; var vias: [VolumeVia]
        var features: [VolumeFeature]; var testPoints: [VolumeTestPoint]
        var sections: [VolumeSection]
    }
    var raw: [RawVolume] = []
    for (root, holes) in holesByRoot {
        let plate = holes.first!.layer.plate
        let holeOrder: (VolumeHole, VolumeHole) -> Bool = {
            ($0.layer.depth, $0.pos.x, $0.pos.y) < ($1.layer.depth, $1.pos.x, $1.pos.y)
        }
        let sortedHoles = holes.sorted(by: holeOrder)
        let sections = (sectionsByRoot[root] ?? [:]).values
            .map { sec -> VolumeSection in
                var s = sec; s.holes.sort(by: holeOrder); return s
            }
            .sorted { a, b in
                guard let ha = a.holes.first, let hb = b.holes.first else { return a.holes.count > b.holes.count }
                return holeOrder(ha, hb)
            }
        // A resistor-merged cavity spans several nets; name it compactly.
        let labels = (netsByRoot[root] ?? []).sorted()
        let label: String
        switch labels.count {
        case 0:    label = "?"
        case 1, 2: label = labels.joined(separator: " / ")
        default:   label = "\(labels.prefix(2).joined(separator: " / ")) +\(labels.count - 2)"
        }
        raw.append(RawVolume(plate: plate, netLabel: label, nets: netIdsByRoot[root] ?? [],
                             holes: sortedHoles,
                             segments: segsByRoot[root] ?? [],
                             resistors: resByRoot[root] ?? [],
                             vias: viasByRoot[root] ?? [],
                             features: featuresByRoot[root] ?? [],
                             testPoints: tpsByRoot[root] ?? [],
                             sections: sections))
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
        return Volume(id: id, plate: r.plate, netLabel: r.netLabel, nets: r.nets, holes: r.holes,
                      segments: r.segments, resistors: r.resistors, vias: r.vias,
                      features: r.features, testPoints: r.testPoints, sections: r.sections)
    }
}
