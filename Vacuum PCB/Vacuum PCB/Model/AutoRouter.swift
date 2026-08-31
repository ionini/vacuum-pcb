import Foundation

/// Quick-and-dirty grid-based auto-router.
///
/// Per net we build a Kruskal MST over placed pins and try to A*-route each
/// pair over a two-layer grid (top + bottom). Layer changes inside A* cost
/// extra so the planner prefers same-plate routes but will drop a via when
/// the cheaper path needs the other plate.
///
/// Single-pass, no rip-up. Nets already connected through existing routes
/// are skipped. Anything that fails to route stays in the ratsnest for
/// manual fixing.
enum AutoRouter {
    /// Runs the router against the document state and returns segments that
    /// should be added. The caller mutates the document so the run is
    /// undoable in one Codable snapshot.
    static func plan(_ doc: CircuitDocument) -> [(netId: UUID, segment: Segment)] {
        let pitch = doc.manufacturing.gridPitch
        let outline = doc.physical.boardOutline
        guard pitch > 0, outline.size.width > 0, outline.size.height > 0 else { return [] }

        // Clearance halo: stamp `halo` cells around each centerline cell so
        // a parallel route can't sit closer than `minChannelSpacing` (cell-
        // to-cell distance). Halo of N cells leaves at least N+1 cells of
        // separation between centerlines → (N+1) × pitch mm.
        let halo = max(1, Int((doc.manufacturing.minChannelSpacing / pitch).rounded(.up)) - 1)

        // One occupancy grid per channel layer (plate + depth). Multi-layer
        // plates stack depths outward; the router can drop a via between
        // adjacent depths inside a plate, and the cross-silicone via still
        // joins the two depth-0 layers.
        let layers = doc.physical.layers(in: .top) + doc.physical.layers(in: .bottom)
        var grids: [Layer: OccupancyGrid] = [:]
        for layer in layers { grids[layer] = OccupancyGrid(outline: outline, pitch: pitch) }

        // 1. Seed occupancy with already-drawn route polylines, on their layer.
        for route in doc.physical.routes {
            for segment in route.segments {
                guard let grid = grids[segment.layer] else { continue }
                let pts = segment.waypoints.map(\.position)
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    grid.markLine(pts[i], pts[i + 1], halo: halo)
                }
            }
        }
        // 2. Seed with resistor serpentines so they don't get crossed.
        seedComponentFeatures(in: doc, grids: grids, halo: halo)
        // 3. Clear a tight neighbourhood around every placed pin so A* can
        //    always enter/exit pin cells, even if a previous route's halo
        //    stamped over them. Pins themselves don't count as obstacles
        //    here — they're attachment points, not channels.
        clearPinNeighborhoods(in: doc, grids: grids)
        // 4. Component exclusion zones block via insertion. Routes can still
        //    pass through (the cells aren't marked on the per-layer grids
        //    unless something else put them there), but a via punching the
        //    plate inside a transistor's dimple or a resistor's body would
        //    wreck the part — explicitly disallow that.
        let noVias = OccupancyGrid(outline: outline, pitch: pitch)
        seedNoViaZones(in: doc, grid: noVias)

        var planned: [(netId: UUID, segment: Segment)] = []

        // 5. Route nets in a stable order. For each net, build an MST over
        //    placed pins and try the multi-layer A* on each MST edge, routing
        //    from each pin's own layer (plate + depth) to the other's.
        for net in doc.logic.nets {
            let placed = placedPins(for: net, in: doc)
            guard placed.count >= 2 else { continue }

            // Skip net pairs already electrically connected via existing routes.
            let alreadyConnected = connectivityMap(net: net, in: doc, pinPositions: placed.map(\.position))

            for edge in mstEdges(placed.map(\.position)) {
                let a = placed[edge.i]
                let b = placed[edge.j]
                if alreadyConnected.same(edge.i, edge.j) { continue }
                guard let path = AStarML.run(
                    grids: grids, noVias: noVias, layers: layers,
                    from: a.position, fromLayer: a.layer,
                    to: b.position, toLayer: b.layer
                ) else { continue }
                var segments = pathToSegments(path)
                // A* operates on the manufacturing grid, but pin offsets
                // (especially the transistor's ±1.5 mm a/b pads) often land
                // off-grid. The path's first and last waypoints would
                // otherwise sit at the *nearest* grid cell, leaving the
                // route ~half-a-pitch short of the actual pin — DRC then
                // reports it as disconnected. Replace those endpoints with
                // the exact pin world positions so the polyline literally
                // terminates on the pin (introducing a tiny diagonal
                // pin→grid jog, which the CAD pipeline sweeps fine).
                snapSegmentEndpointsToPins(&segments, startPin: a.position, endPin: b.position)
                for seg in segments {
                    planned.append((net.id, seg))
                    // Mark the new segment in its layer's grid so subsequent
                    // routes (in this run) avoid it.
                    guard let grid = grids[seg.layer] else { continue }
                    let pts = seg.waypoints.map(\.position)
                    for i in 0..<(pts.count - 1) {
                        grid.markLine(pts[i], pts[i + 1], halo: halo)
                    }
                }
            }
        }

        return planned
    }

    /// Splits a multi-layer A* path into one Segment per contiguous same-layer
    /// run. Cells where the path changes layer — whether crossing the silicone
    /// (top↔bottom at depth 0) or stepping between depths inside one plate —
    /// become matching `.via` waypoints: one at the end of the outgoing
    /// segment, one at the start of the incoming segment, both at the same XY.
    /// Same model the manual V-key routing uses.
    private static func pathToSegments(_ path: [(point: Point, layer: Layer)]) -> [Segment] {
        guard !path.isEmpty else { return [] }
        var segments: [Segment] = []
        var currentLayer = path[0].layer
        var currentWaypoints: [Waypoint] = [Waypoint(position: path[0].point, kind: .point)]
        for i in 1..<path.count {
            let prev = path[i - 1]
            let cur = path[i]
            if cur.layer != prev.layer {
                // Replace the trailing waypoint of the current segment with
                // a .via, then start a fresh segment on the new layer also
                // beginning at this shared XY as a .via.
                if let last = currentWaypoints.last {
                    currentWaypoints[currentWaypoints.count - 1] =
                        Waypoint(position: last.position, kind: .via)
                }
                segments.append(Segment(
                    waypoints: compactWaypoints(currentWaypoints),
                    layer: currentLayer
                ))
                currentLayer = cur.layer
                currentWaypoints = [Waypoint(position: cur.point, kind: .via)]
            } else {
                currentWaypoints.append(Waypoint(position: cur.point, kind: .point))
            }
        }
        segments.append(Segment(
            waypoints: compactWaypoints(currentWaypoints),
            layer: currentLayer
        ))
        // Drop any degenerate single-waypoint segments that would survive a
        // zero-length layer change at the end of the path.
        return segments.filter { $0.waypoints.count >= 2 }
    }

    /// Replaces the first segment's first waypoint with `startPin` and the
    /// last segment's last waypoint with `endPin`. Keeps the existing kind
    /// (`.point` for plain endpoints, `.via` if A* started/ended at a via
    /// — shouldn't happen here, the route starts at a pin, but cheap to
    /// preserve).
    private static func snapSegmentEndpointsToPins(
        _ segments: inout [Segment], startPin: Point, endPin: Point
    ) {
        guard !segments.isEmpty else { return }
        if !segments[0].waypoints.isEmpty {
            let kind = segments[0].waypoints[0].kind
            segments[0].waypoints[0] = Waypoint(position: startPin, kind: kind)
        }
        let lastSegIdx = segments.count - 1
        let lastWpIdx = segments[lastSegIdx].waypoints.count - 1
        if lastWpIdx >= 0 {
            let kind = segments[lastSegIdx].waypoints[lastWpIdx].kind
            segments[lastSegIdx].waypoints[lastWpIdx] = Waypoint(position: endPin, kind: kind)
        }
    }

    /// Like `compactPolyline` but preserves any `.via` waypoint regardless
    /// of colinearity — vias mark layer transitions and must stay.
    private static func compactWaypoints(_ wps: [Waypoint]) -> [Waypoint] {
        guard wps.count > 2 else { return wps }
        var out: [Waypoint] = [wps[0]]
        for i in 1..<(wps.count - 1) {
            let a = out.last!.position
            let b = wps[i].position
            let c = wps[i + 1].position
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(cross) > 0.001 || wps[i].kind == .via {
                out.append(wps[i])
            }
        }
        out.append(wps.last!)
        return out
    }

    // MARK: - Negotiated-congestion (PathFinder) router

    /// Routes **every** net from scratch using negotiated congestion — the
    /// standard fix for the single-pass router's failure mode, where nets
    /// routed early hog channels and later nets can't get through (the bulk of
    /// the DRC on a dense board). Unlike `plan`, routes are *soft*: a cell
    /// already used by another net costs more but isn't impassable, so A*
    /// always finds *a* path; then over several rounds the cost of contested
    /// cells is raised (present congestion + accumulated history) until the
    /// nets negotiate themselves apart. Sub-part bodies and resistor
    /// serpentines stay *hard* obstacles.
    ///
    /// Returns the same `(netId, segment)` shape as `plan` so callers add the
    /// segments the same way. `rounds` caps the negotiation; it stops early
    /// once no two nets' channels are within clearance.
    ///
    /// `ripUp` selects which nets to (re)route. `nil` routes **all** nets from
    /// scratch (ignoring existing routes). A non-nil set routes only those
    /// nets, treating every *other* net's existing route as a fixed hard
    /// obstacle — the incremental rip-up the minimizer leans on: move a part,
    /// rip up the nets it disturbs (plus any congested neighbours), and let
    /// them renegotiate around everything left in place. The caller is
    /// responsible for removing the ripped nets' old routes before adding the
    /// returned segments.
    static func planNegotiated(_ doc: CircuitDocument, ripUp: Set<UUID>? = nil, rounds: Int = 14,
                               bendPenalty: Double = 0.5)
        -> [(netId: UUID, segment: Segment)] {
        let pitch = doc.manufacturing.gridPitch
        let outline = doc.physical.boardOutline
        guard pitch > 0, outline.size.width > 0, outline.size.height > 0 else { return [] }
        let halo = max(1, Int((doc.manufacturing.minChannelSpacing / pitch).rounded(.up)) - 1)
        let layers = doc.physical.layers(in: .top) + doc.physical.layers(in: .bottom)
        guard !layers.isEmpty else { return [] }

        // Hard obstacles: sub-part bodies (all layers) + resistor serpentines
        // (their layer), with placed pins punched back open so routes can dock.
        // Existing routes are ignored — this is a from-scratch plan.
        var blocked: [Layer: OccupancyGrid] = [:]
        for l in layers { blocked[l] = OccupancyGrid(outline: outline, pitch: pitch) }
        seedComponentFeatures(in: doc, grids: blocked, halo: halo)
        let noVias = OccupancyGrid(outline: outline, pitch: pitch)
        seedNoViaZones(in: doc, grid: noVias)
        seedSubpartObstacles(in: doc, grids: blocked, noVias: noVias, halo: halo)
        // Incremental mode: every net NOT being ripped up keeps its current
        // route, seeded as a fixed obstacle so the ripped nets route around it.
        if let ripUp {
            for route in doc.physical.routes where !ripUp.contains(route.netId) {
                for seg in route.segments {
                    guard let grid = blocked[seg.layer] else { continue }
                    let pts = seg.waypoints.map(\.position)
                    guard pts.count >= 2 else { continue }
                    for i in 0..<(pts.count - 1) { grid.markLine(pts[i], pts[i + 1], halo: halo) }
                }
            }
        }
        clearPinNeighborhoods(in: doc, grids: blocked)

        let anyGrid = blocked[layers[0]]!
        let cols = anyGrid.cols, rows = anyGrid.rows
        let cellCount = cols * rows
        let layerCount = layers.count
        let blockedArr: [OccupancyGrid] = layers.map { blocked[$0]! }
        let layerIndex = Dictionary(uniqueKeysWithValues: layers.enumerated().map { ($1, $0) })
        func flat(_ l: Int, _ i: Int, _ j: Int) -> Int { l * cellCount + j * cols + i }

        struct Conn { let a: Point; let aL: Int; let b: Point; let bL: Int }
        struct Job { let id: UUID; let conns: [Conn] }
        var jobs: [Job] = []
        for net in doc.logic.nets {
            if let ripUp, !ripUp.contains(net.id) { continue }
            let placed = placedPins(for: net, in: doc)
            guard placed.count >= 2 else { continue }
            var conns: [Conn] = []
            for e in mstEdges(placed.map(\.position)) {
                let a = placed[e.i], b = placed[e.j]
                guard let aL = layerIndex[a.layer], let bL = layerIndex[b.layer] else { continue }
                conns.append(Conn(a: a.position, aL: aL, b: b.position, bL: bL))
            }
            if !conns.isEmpty { jobs.append(Job(id: net.id, conns: conns)) }
        }

        // PathFinder fields, flat over (layer, cell).
        var stamp = [Int](repeating: 0, count: layerCount * cellCount)     // # nets within clearance
        var history = [Double](repeating: 0, count: layerCount * cellCount) // accumulated congestion
        var netStampCells = [UUID: [Int]]()                                 // this net's stamped flats
        var netResult = [UUID: [(path: [(point: Point, layer: Layer)], a: Point, b: Point)]]()

        var pFactor = 0.6
        for _ in 0..<rounds {
            for job in jobs {
                // Rip up: remove this net's stamp from the present field.
                if let cells = netStampCells[job.id] { for f in cells { stamp[f] -= 1 } }
                netStampCells[job.id] = nil

                var centers = Set<Int>()
                var results: [(path: [(point: Point, layer: Layer)], a: Point, b: Point)] = []
                for conn in job.conns {
                    guard let path = AStarCost.run(
                        blocked: blockedArr, noVias: noVias, layers: layers,
                        cols: cols, rows: rows, cellCount: cellCount,
                        stamp: stamp, history: history, pFactor: pFactor,
                        from: conn.a, fromLayer: conn.aL, to: conn.b, toLayer: conn.bL,
                        bendPenalty: bendPenalty
                    ) else { continue }
                    results.append((path, conn.a, conn.b))
                    for (pt, lay) in path {
                        let (ci, cj) = anyGrid.toGrid(pt)
                        guard let li = layerIndex[lay], anyGrid.inBounds(ci, cj) else { continue }
                        centers.insert(flat(li, ci, cj))
                    }
                }
                netResult[job.id] = results

                // Stamp = centerline dilated by the clearance halo. Two nets
                // conflict when one's centerline lands on another's stamp —
                // exactly the boolean router's collision model, made soft.
                var stampCells = Set<Int>()
                for fc in centers {
                    let li = fc / cellCount, cell = fc % cellCount
                    let ci = cell % cols, cj = cell / cols
                    for dy in -halo...halo {
                        for dx in -halo...halo {
                            let ni = ci + dx, nj = cj + dy
                            if ni >= 0, ni < cols, nj >= 0, nj < rows { stampCells.insert(flat(li, ni, nj)) }
                        }
                    }
                }
                let arr = Array(stampCells)
                netStampCells[job.id] = arr
                for f in arr { stamp[f] += 1 }
            }

            // Raise history wherever a net's centerline sits on a cell another
            // net also stamps. Converged when there's no such overlap.
            var overuse = false
            for job in jobs {
                guard let results = netResult[job.id] else { continue }
                let selfCells = Set(netStampCells[job.id] ?? [])
                for (path, _, _) in results {
                    for (pt, lay) in path {
                        let (ci, cj) = anyGrid.toGrid(pt)
                        guard let li = layerIndex[lay], anyGrid.inBounds(ci, cj) else { continue }
                        let f = flat(li, ci, cj)
                        let others = stamp[f] - (selfCells.contains(f) ? 1 : 0)
                        if others > 0 { history[f] += 1; overuse = true }
                    }
                }
            }
            pFactor *= 1.7
            if !overuse { break }
        }

        var planned: [(netId: UUID, segment: Segment)] = []
        for job in jobs {
            guard let results = netResult[job.id] else { continue }
            for r in results {
                var segs = pathToSegments(r.path)
                snapSegmentEndpointsToPins(&segs, startPin: r.a, endPin: r.b)
                for s in segs { planned.append((job.id, s)) }
            }
        }
        return planned
    }

    // MARK: - Helpers

    private struct PlacedPin {
        let position: Point
        let layer: Layer
    }

    private static func placedPins(for net: Net, in doc: CircuitDocument) -> [PlacedPin] {
        var out: [PlacedPin] = []
        for ref in net.pins {
            guard let placement = doc.physical.placements.first(where: { $0.componentId == ref.componentId }),
                  let component = doc.logic.components.first(where: { $0.id == ref.componentId }),
                  let fp = component.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pin(ref.pinKey)
            else { continue }
            out.append(PlacedPin(
                position: placement.worldPosition(of: fp),
                layer: placement.resolvedLayer(of: fp, on: component)
            ))
        }
        return out
    }

    /// Union-find over routed segments + pin positions, indexed by pin order
    /// in `pinPositions`. Lets the router skip MST edges whose endpoints are
    /// already on the same electrical net via existing routing.
    private struct ConnectivityMap {
        var parent: [Int]
        func find(_ x: Int) -> Int {
            var c = x
            while parent[c] != c { c = parent[c] }
            return c
        }
        func same(_ a: Int, _ b: Int) -> Bool { find(a) == find(b) }
    }

    private static func connectivityMap(
        net: Net, in doc: CircuitDocument, pinPositions: [Point]
    ) -> ConnectivityMap {
        var parent = Array(0..<pinPositions.count)
        func find(_ x: Int) -> Int {
            var c = x
            while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }
            return c
        }
        func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        // Pins are connected when their positions share a route-graph node.
        var positionNodes: [Point] = []
        let eps = 0.05
        func nodeIndex(for p: Point) -> Int {
            for (i, q) in positionNodes.enumerated() where abs(q.x - p.x) < eps && abs(q.y - p.y) < eps {
                return i
            }
            positionNodes.append(p)
            return positionNodes.count - 1
        }
        var routeParent: [Int] = []
        func ensure(_ i: Int) { while routeParent.count <= i { routeParent.append(routeParent.count) } }
        func routeFind(_ x: Int) -> Int {
            ensure(x)
            var c = x
            while routeParent[c] != c { routeParent[c] = routeParent[routeParent[c]]; c = routeParent[c] }
            return c
        }
        func routeUnion(_ a: Int, _ b: Int) {
            let ra = routeFind(a), rb = routeFind(b)
            if ra != rb { routeParent[ra] = rb }
        }
        let pinNodes = pinPositions.map { nodeIndex(for: $0) }
        for route in doc.physical.routes where route.netId == net.id {
            for segment in route.segments where segment.waypoints.count >= 2 {
                let ids = segment.waypoints.map { nodeIndex(for: $0.position) }
                for i in 0..<(ids.count - 1) { routeUnion(ids[i], ids[i + 1]) }
            }
        }
        for i in 0..<pinPositions.count {
            for j in (i + 1)..<pinPositions.count
            where routeFind(pinNodes[i]) == routeFind(pinNodes[j]) {
                union(i, j)
            }
        }
        return ConnectivityMap(parent: parent)
    }

    private static func mstEdges(_ pinPositions: [Point]) -> [(i: Int, j: Int)] {
        guard pinPositions.count >= 2 else { return [] }
        struct E { let i, j: Int; let d: Double }
        var pairs: [E] = []
        for i in 0..<pinPositions.count {
            for j in (i + 1)..<pinPositions.count {
                let dx = pinPositions[i].x - pinPositions[j].x
                let dy = pinPositions[i].y - pinPositions[j].y
                pairs.append(E(i: i, j: j, d: dx * dx + dy * dy))
            }
        }
        pairs.sort { $0.d < $1.d }
        var parent = Array(0..<pinPositions.count)
        func find(_ x: Int) -> Int {
            var c = x
            while parent[c] != c { parent[c] = parent[parent[c]]; c = parent[c] }
            return c
        }
        var edges: [(i: Int, j: Int)] = []
        for p in pairs {
            let ri = find(p.i), rj = find(p.j)
            if ri != rj {
                parent[ri] = rj
                edges.append((p.i, p.j))
                if edges.count == pinPositions.count - 1 { break }
            }
        }
        return edges
    }

    /// Stamp resistor serpentines into the occupancy grid of the layer they
    /// sit on so auto-routes don't drive through them.
    private static func seedComponentFeatures(
        in doc: CircuitDocument, grids: [Layer: OccupancyGrid], halo: Int
    ) {
        for placement in doc.physical.placements {
            guard let component = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            switch component.kind {
            case .resistor:
                let local = ResistorGeometry.waypoints(for: component.resistorSize ?? .medium,
                                                       m: doc.manufacturing)
                let world = local.map { localToWorld($0, placement: placement) }
                guard let grid = grids[Layer(plate: placement.layer, depth: placement.depth)] else { continue }
                for i in 0..<(world.count - 1) {
                    grid.markLine(world[i], world[i + 1], halo: halo)
                }
            default:
                break
            }
        }
    }

    /// Seeds every sub-part's **actual internal geometry** as obstacles, in
    /// parent coordinates: its internal route polylines and resistor
    /// serpentines become hard channel blocks (so an external route can't cut
    /// through them and electrically merge), and its internal vertical bores
    /// (transistor / LED dimples, resistor bodies) join the no-via mask. The
    /// sub-part's *empty interior* is deliberately left open, so the bus lines
    /// can thread through the same whitespace the hand-routing uses — blocking
    /// the whole footprint box instead would wall off a board-spanning
    /// sub-part like U1 and strand half the nets. `clearPinNeighborhoods`
    /// re-opens the boundary pins afterward so routes can still dock.
    private static func seedSubpartObstacles(
        in doc: CircuitDocument, grids: [Layer: OccupancyGrid],
        noVias: OccupancyGrid, halo: Int
    ) {
        for placement in doc.physical.placements {
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let part = comp.resolvedPart(snapshots: doc.librarySnapshots)
            else { continue }
            // Expand nested sub-parts so `child` is all primitives, then map
            // child (library) coordinates into the parent board.
            let child = part.document.flattened()
            let outline = part.document.physical.boardOutline
            let ox = outline.minX, oy = outline.minY
            let r = placement.rotation.radians, cr = cos(r), sr = sin(r)
            func toWorld(_ p: Point) -> Point {
                let dx = p.x - ox, dy = p.y - oy
                return Point(x: placement.position.x + dx * cr - dy * sr,
                             y: placement.position.y + dx * sr + dy * cr)
            }

            // Internal routes → hard blocks on their own layers.
            for route in child.physical.routes {
                for seg in route.segments {
                    guard let grid = grids[seg.layer] else { continue }
                    let pts = seg.waypoints.map { toWorld($0.position) }
                    guard pts.count >= 2 else { continue }
                    for i in 0..<(pts.count - 1) { grid.markLine(pts[i], pts[i + 1], halo: halo) }
                }
            }
            // Internal resistor serpentines → hard blocks; internal vertical
            // bores → no-via mask.
            for ip in child.physical.placements {
                guard let ic = child.logic.components.first(where: { $0.id == ip.componentId })
                else { continue }
                switch ic.kind {
                case .resistor:
                    // The sub-part's serpentines were built with the sub-part's
                    // own manufacturing constants — stamp those, not the parent's.
                    let local = ResistorGeometry.waypoints(for: ic.resistorSize ?? .medium,
                                                           m: child.manufacturing)
                    let pts = local.map { toWorld(localToWorld($0, placement: ip)) }
                    if let grid = grids[Layer(plate: ip.layer, depth: ip.depth)] {
                        for i in 0..<(pts.count - 1) { grid.markLine(pts[i], pts[i + 1], halo: halo) }
                    }
                    seedNoViaRect(ic.footprint(doc.manufacturing).exclusionRect, ip, toWorld, into: noVias)
                case .transistor, .led:
                    seedNoViaRect(ic.footprint(doc.manufacturing).exclusionRect, ip, toWorld, into: noVias)
                default:
                    break
                }
            }
        }
    }

    /// Marks a footprint exclusion rect (under an internal placement's
    /// rotation, then the parent transform) into the no-via mask.
    private static func seedNoViaRect(
        _ rect: Rect, _ ip: Placement, _ toWorld: (Point) -> Point, into grid: OccupancyGrid
    ) {
        if rect.size.width == 0, rect.size.height == 0 { return }
        let r = ip.rotation.radians, c = cos(r), s = sin(r)
        let corners = [
            Point(x: rect.minX, y: rect.minY), Point(x: rect.maxX, y: rect.minY),
            Point(x: rect.maxX, y: rect.maxY), Point(x: rect.minX, y: rect.maxY),
        ].map { local -> Point in
            let lx = ip.position.x + local.x * c - local.y * s
            let ly = ip.position.y + local.x * s + local.y * c
            return toWorld(Point(x: lx, y: ly))
        }
        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        let (i0, j0) = grid.toGrid(Point(x: minX, y: minY))
        let (i1, j1) = grid.toGrid(Point(x: maxX, y: maxY))
        guard i0 <= i1, j0 <= j1 else { return }
        for j in j0...j1 { for i in i0...i1 { grid.mark(i, j) } }
    }

    /// Carves a 1-cell-radius "pad" around every placed pin in the document
    /// on the pin's resolved layer. Two things this fixes:
    ///  * a previous route's halo can otherwise block A* from expanding out
    ///    of a pin (start/goal cell exempt, but immediate neighbours aren't),
    ///  * the next net's pin won't be unreachable just because it landed
    ///    adjacent to an earlier route.
    private static func clearPinNeighborhoods(
        in doc: CircuitDocument, grids: [Layer: OccupancyGrid]
    ) {
        for placement in doc.physical.placements {
            guard let component = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            for fpPin in component.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).pins {
                let world = placement.worldPosition(of: fpPin)
                guard let grid = grids[placement.resolvedLayer(of: fpPin, on: component)] else { continue }
                let (cx, cy) = grid.toGrid(world)
                for dy in -1...1 {
                    for dx in -1...1 {
                        grid.clear(cx + dx, cy + dy)
                    }
                }
            }
        }
    }

    /// Stamps every placement's footprint exclusion zone into the no-via
    /// mask. We rotate the rect's corners by the placement rotation, walk
    /// the world AABB of the rotated quadrilateral, and mark each cell —
    /// good enough for our small components (3–12 mm long sides) where the
    /// AABB is only a hair larger than the true rotated rect.
    private static func seedNoViaZones(in doc: CircuitDocument, grid: OccupancyGrid) {
        for placement in doc.physical.placements {
            guard let component = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            let rect = component.footprint(doc.manufacturing, snapshots: doc.librarySnapshots).exclusionRect
            let r = placement.rotation.radians
            let cs = cos(r), sn = sin(r)
            let cornersLocal = [
                Point(x: rect.minX, y: rect.minY),
                Point(x: rect.maxX, y: rect.minY),
                Point(x: rect.maxX, y: rect.maxY),
                Point(x: rect.minX, y: rect.maxY)
            ]
            let cornersWorld = cornersLocal.map { p in
                Point(
                    x: placement.position.x + p.x * cs - p.y * sn,
                    y: placement.position.y + p.x * sn + p.y * cs
                )
            }
            let minX = cornersWorld.map(\.x).min() ?? 0
            let maxX = cornersWorld.map(\.x).max() ?? 0
            let minY = cornersWorld.map(\.y).min() ?? 0
            let maxY = cornersWorld.map(\.y).max() ?? 0
            let (i0, j0) = grid.toGrid(Point(x: minX, y: minY))
            let (i1, j1) = grid.toGrid(Point(x: maxX, y: maxY))
            for j in j0...j1 {
                for i in i0...i1 {
                    grid.mark(i, j)
                }
            }
        }
    }

    private static func localToWorld(_ p: Point, placement: Placement) -> Point {
        let r = placement.rotation.radians
        let c = cos(r), s = sin(r)
        return Point(
            x: placement.position.x + p.x * c - p.y * s,
            y: placement.position.y + p.x * s + p.y * c
        )
    }
}

// MARK: - Occupancy grid

/// Reference-type so segments can stamp into the same grid without copying
/// each `markLine` call. Cells store `false` for free, `true` for blocked.
final class OccupancyGrid {
    let outline: Rect
    let pitch: Double
    let cols: Int
    let rows: Int
    private var cells: [Bool]

    init(outline: Rect, pitch: Double) {
        self.outline = outline
        self.pitch = pitch
        self.cols = max(1, Int((outline.size.width / pitch).rounded(.up)) + 1)
        self.rows = max(1, Int((outline.size.height / pitch).rounded(.up)) + 1)
        self.cells = Array(repeating: false, count: cols * rows)
    }

    func toGrid(_ p: Point) -> (Int, Int) {
        let cx = Int(((p.x - outline.origin.x) / pitch).rounded())
        let cy = Int(((p.y - outline.origin.y) / pitch).rounded())
        return (cx, cy)
    }

    func toWorld(_ i: Int, _ j: Int) -> Point {
        Point(x: outline.origin.x + Double(i) * pitch,
              y: outline.origin.y + Double(j) * pitch)
    }

    func inBounds(_ i: Int, _ j: Int) -> Bool {
        i >= 0 && i < cols && j >= 0 && j < rows
    }

    func isBlocked(_ i: Int, _ j: Int) -> Bool {
        inBounds(i, j) ? cells[j * cols + i] : true
    }

    func mark(_ i: Int, _ j: Int) {
        guard inBounds(i, j) else { return }
        cells[j * cols + i] = true
    }

    func clear(_ i: Int, _ j: Int) {
        guard inBounds(i, j) else { return }
        cells[j * cols + i] = false
    }

    /// Bresenham-ish: mark every grid cell whose centre is within `halo`
    /// cells of the line from `a` to `b`.
    func markLine(_ a: Point, _ b: Point, halo: Int) {
        let (x0, y0) = toGrid(a)
        let (x1, y1) = toGrid(b)
        let dx = abs(x1 - x0), dy = abs(y1 - y0)
        let sx = x0 < x1 ? 1 : -1
        let sy = y0 < y1 ? 1 : -1
        var err = dx - dy
        var x = x0, y = y0
        while true {
            stampHalo(at: x, y, halo: halo)
            if x == x1 && y == y1 { break }
            let e2 = err * 2
            if e2 > -dy { err -= dy; x += sx }
            if e2 < dx { err += dx; y += sy }
        }
    }

    private func stampHalo(at i: Int, _ j: Int, halo: Int) {
        for dy in -halo...halo {
            for dx in -halo...halo {
                mark(i + dx, j + dy)
            }
        }
    }
}

// MARK: - Multi-layer A*

/// A* over a (cell, layer, arrival-direction) state space, where `layer` is a
/// full plate + depth. Same-layer 4-connected steps cost 1; a step that *turns*
/// costs an extra `bendPenalty`, so among equal-length grid paths the planner
/// prefers the one with the fewest corners — a straight run instead of a
/// staircase. A via costs `viaCost` (default 6) so plain runs are preferred and
/// the planner only changes layer when it pays off. A via may either cross the
/// silicone (top↔bottom at depth 0) or step between adjacent depths inside one
/// plate. Vias are forbidden where the `noVias` mask is set (under component
/// bodies) or where the destination layer's cell is already occupied by another
/// channel.
enum AStarML {
    static func run(
        grids: [Layer: OccupancyGrid],
        noVias: OccupancyGrid,
        layers: [Layer],
        from start: Point, fromLayer: Layer,
        to goal: Point, toLayer: Layer,
        viaCost: Int = 6,
        bendPenalty: Int = 1
    ) -> [(point: Point, layer: Layer)]? {
        guard let startLayer = layers.firstIndex(of: fromLayer),
              let goalLayer = layers.firstIndex(of: toLayer),
              let anyGrid = grids[layers.first ?? fromLayer]
        else { return nil }

        let (sx, sy) = anyGrid.toGrid(start)
        let (gx, gy) = anyGrid.toGrid(goal)
        guard anyGrid.inBounds(sx, sy), anyGrid.inBounds(gx, gy) else { return nil }

        let cols = anyGrid.cols
        let cells = cols * anyGrid.rows
        let layerCount = layers.count
        // Resolve each layer index to its grid up front — dictionary lookups
        // in the inner loop would dominate the run.
        let gridForLayer: [OccupancyGrid] = layers.map { grids[$0] ?? anyGrid }

        // Via adjacency: which layer indices each layer can drop a via to —
        // adjacent depths within a plate, plus the cross-silicone hop joining
        // the two depth-0 layers.
        var viaAdj: [[Int]] = Array(repeating: [], count: layerCount)
        for (a, la) in layers.enumerated() {
            for (b, lb) in layers.enumerated() where a != b {
                let samePlateStep = la.plate == lb.plate && abs(la.depth - lb.depth) == 1
                let crossSilicone = la.depth == 0 && lb.depth == 0 && la.plate != lb.plate
                if samePlateStep || crossSilicone { viaAdj[a].append(b) }
            }
        }

        // The arrival direction (which of the 4 neighbours we stepped from) is
        // part of the state so a turn can be priced. Direction 4 = "none": the
        // start, and the cell just after a via, have no incoming heading, so
        // their next move is free in any direction.
        let dirCount = 5
        let noneDir = 4
        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        func base(_ i: Int, _ j: Int, _ l: Int) -> Int { l * cells + j * cols + i }
        func stateIdx(_ i: Int, _ j: Int, _ l: Int, _ d: Int) -> Int { base(i, j, l) * dirCount + d }
        func heuristic(_ i: Int, _ j: Int, _ l: Int) -> Int {
            abs(i - gx) + abs(j - gy) + (l == goalLayer ? 0 : viaCost)
        }

        let goalBase = base(gx, gy, goalLayer)
        let total = cells * layerCount * dirCount
        var gScore = Array(repeating: Int.max, count: total)
        var parent = Array(repeating: -1, count: total)
        var visited = Array(repeating: false, count: total)
        let startIdx = stateIdx(sx, sy, startLayer, noneDir)
        gScore[startIdx] = 0

        var open = MinHeap()
        open.push(f: heuristic(sx, sy, startLayer), state: startIdx)

        while let popped = open.pop() {
            let current = popped.state
            if visited[current] { continue }   // stale duplicate (lazy deletion)
            visited[current] = true
            let b = current / dirCount
            if b == goalBase {
                return reconstruct(parent: parent, goalIdx: current,
                                   cells: cells, cols: cols, dirCount: dirCount,
                                   layers: layers, gridForLayer: gridForLayer)
            }
            let curDir = current % dirCount
            let l = b / cells
            let rem = b % cells
            let ci = rem % cols, cj = rem / cols

            // Same-layer 4-connected moves; a change of heading costs `bendPenalty`.
            let curGrid = gridForLayer[l]
            for (dirIndex, (dx, dy)) in neighbours.enumerated() {
                let ni = ci + dx, nj = cj + dy
                guard curGrid.inBounds(ni, nj) else { continue }
                let isGoalCell = (ni == gx && nj == gy && l == goalLayer)
                if curGrid.isBlocked(ni, nj), !isGoalCell { continue }
                let bend = curDir != noneDir && curDir != dirIndex
                let nIdx = stateIdx(ni, nj, l, dirIndex)
                let tentative = gScore[current] + 1 + (bend ? bendPenalty : 0)
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = current
                    open.push(f: tentative + heuristic(ni, nj, l), state: nIdx)
                }
            }
            // Via to an adjacent layer at this cell. The destination cell must
            // be free (don't punch through an existing channel there) and the
            // cell must be outside the no-via mask (no bores under component
            // bodies — transistor dimples, resistors, port bores). The via
            // carries the current heading through unchanged — going straight
            // across a via isn't a corner, but turning after it is.
            if !noVias.isBlocked(ci, cj) {
                for nl in viaAdj[l] {
                    let isGoalCell = (ci == gx && cj == gy && nl == goalLayer)
                    if gridForLayer[nl].isBlocked(ci, cj), !isGoalCell { continue }
                    let nIdx = stateIdx(ci, cj, nl, curDir)
                    let tentative = gScore[current] + viaCost
                    if tentative < gScore[nIdx] {
                        gScore[nIdx] = tentative
                        parent[nIdx] = current
                        open.push(f: tentative + heuristic(ci, cj, nl), state: nIdx)
                    }
                }
            }
        }
        return nil
    }

    private static func reconstruct(
        parent: [Int], goalIdx: Int, cells: Int, cols: Int, dirCount: Int,
        layers: [Layer], gridForLayer: [OccupancyGrid]
    ) -> [(point: Point, layer: Layer)] {
        var result: [(Point, Layer)] = []
        var idx = goalIdx
        while idx >= 0 {
            let b = idx / dirCount
            let l = b / cells
            let rem = b % cells
            let i = rem % cols
            let j = rem / cols
            result.append((gridForLayer[l].toWorld(i, j), layers[l]))
            let next = parent[idx]
            if next == idx || next < 0 { break }
            idx = next
        }
        return result.reversed().map { (point: $0.0, layer: $0.1) }
    }
}

// MARK: - Cost-based multi-layer A* (negotiated congestion)

/// Like `AStarML` but over a real-valued cost field: each step's cost is
/// `1 + history[cell] + pFactor·stamp[cell]` (vias use `viaCost` as the base),
/// so a path is steered away from congested cells without ever being blocked
/// by them. A step that *turns* additionally costs `bendPenalty`, so the path
/// stays straight wherever congestion doesn't force a detour. Only sub-part
/// bodies / resistor serpentines (the `blocked` grids) and the no-via mask are
/// hard constraints. `stamp` / `history` are flat arrays indexed
/// `layer·cellCount + j·cols + i`, matching `planNegotiated`.
enum AStarCost {
    static func run(
        blocked: [OccupancyGrid], noVias: OccupancyGrid, layers: [Layer],
        cols: Int, rows: Int, cellCount: Int,
        stamp: [Int], history: [Double], pFactor: Double,
        from start: Point, fromLayer: Int,
        to goal: Point, toLayer: Int,
        viaCost: Double = 6,
        bendPenalty: Double = 0.5
    ) -> [(point: Point, layer: Layer)]? {
        let anyGrid = blocked[0]
        let (sx, sy) = anyGrid.toGrid(start)
        let (gx, gy) = anyGrid.toGrid(goal)
        guard anyGrid.inBounds(sx, sy), anyGrid.inBounds(gx, gy) else { return nil }
        let layerCount = layers.count

        var viaAdj: [[Int]] = Array(repeating: [], count: layerCount)
        for (a, la) in layers.enumerated() {
            for (b, lb) in layers.enumerated() where a != b {
                let samePlateStep = la.plate == lb.plate && abs(la.depth - lb.depth) == 1
                let crossSilicone = la.depth == 0 && lb.depth == 0 && la.plate != lb.plate
                if samePlateStep || crossSilicone { viaAdj[a].append(b) }
            }
        }

        // Arrival direction is part of the state so a turn can be priced (see
        // `AStarML`). Direction 4 = "none": the start and the cell just after a
        // via have no incoming heading, so their next move is penalty-free.
        let dirCount = 5
        let noneDir = 4
        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        func base(_ i: Int, _ j: Int, _ l: Int) -> Int { l * cellCount + j * cols + i }
        func stateIdx(_ i: Int, _ j: Int, _ l: Int, _ d: Int) -> Int { base(i, j, l) * dirCount + d }
        func heuristic(_ i: Int, _ j: Int, _ l: Int) -> Double {
            Double(abs(i - gx) + abs(j - gy)) + (l == toLayer ? 0 : viaCost)
        }

        let goalBase = base(gx, gy, toLayer)
        let total = cellCount * layerCount * dirCount
        var gScore = [Double](repeating: .infinity, count: total)
        var parent = [Int](repeating: -1, count: total)
        var visited = [Bool](repeating: false, count: total)
        let startIdx = stateIdx(sx, sy, fromLayer, noneDir)
        gScore[startIdx] = 0

        var open = DoubleHeap()
        open.push(f: heuristic(sx, sy, fromLayer), state: startIdx)

        while let popped = open.pop() {
            let current = popped.state
            if visited[current] { continue }
            visited[current] = true
            let b = current / dirCount
            if b == goalBase {
                return reconstruct(parent: parent, goalIdx: current,
                                   cellCount: cellCount, cols: cols, dirCount: dirCount,
                                   layers: layers, grids: blocked)
            }
            let curDir = current % dirCount
            let l = b / cellCount
            let rem = b % cellCount
            let ci = rem % cols, cj = rem / cols
            let curGrid = blocked[l]

            for (dirIndex, (dx, dy)) in neighbours.enumerated() {
                let ni = ci + dx, nj = cj + dy
                guard curGrid.inBounds(ni, nj) else { continue }
                let isGoalCell = (ni == gx && nj == gy && l == toLayer)
                if curGrid.isBlocked(ni, nj), !isGoalCell { continue }
                let flat = l * cellCount + nj * cols + ni
                let bend = curDir != noneDir && curDir != dirIndex
                let step = 1 + history[flat] + pFactor * Double(stamp[flat]) + (bend ? bendPenalty : 0)
                let tentative = gScore[current] + step
                let nIdx = stateIdx(ni, nj, l, dirIndex)
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = current
                    open.push(f: tentative + heuristic(ni, nj, l), state: nIdx)
                }
            }
            if !noVias.isBlocked(ci, cj) {
                for nl in viaAdj[l] {
                    let isGoalCell = (ci == gx && cj == gy && nl == toLayer)
                    if blocked[nl].isBlocked(ci, cj), !isGoalCell { continue }
                    let flat = nl * cellCount + cj * cols + ci
                    let step = viaCost + history[flat] + pFactor * Double(stamp[flat])
                    let tentative = gScore[current] + step
                    let nIdx = stateIdx(ci, cj, nl, curDir)
                    if tentative < gScore[nIdx] {
                        gScore[nIdx] = tentative
                        parent[nIdx] = current
                        open.push(f: tentative + heuristic(ci, cj, nl), state: nIdx)
                    }
                }
            }
        }
        return nil
    }

    private static func reconstruct(
        parent: [Int], goalIdx: Int, cellCount: Int, cols: Int, dirCount: Int,
        layers: [Layer], grids: [OccupancyGrid]
    ) -> [(point: Point, layer: Layer)] {
        var result: [(Point, Layer)] = []
        var idx = goalIdx
        while idx >= 0 {
            let b = idx / dirCount
            let l = b / cellCount
            let rem = b % cellCount
            let i = rem % cols, j = rem / cols
            result.append((grids[l].toWorld(i, j), layers[l]))
            let next = parent[idx]
            if next == idx || next < 0 { break }
            idx = next
        }
        return result.reversed().map { (point: $0.0, layer: $0.1) }
    }
}

/// Min-heap keyed on a `Double` f-score — the negotiated router's open set.
/// Same lazy-deletion contract as `MinHeap`.
struct DoubleHeap {
    private var fs: [Double] = []
    private var states: [Int] = []

    mutating func push(f: Double, state: Int) {
        fs.append(f); states.append(state)
        var c = fs.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if fs[p] <= fs[c] { break }
            fs.swapAt(p, c); states.swapAt(p, c)
            c = p
        }
    }

    mutating func pop() -> (f: Double, state: Int)? {
        guard !fs.isEmpty else { return nil }
        let top = (f: fs[0], state: states[0])
        let lastF = fs.removeLast(), lastS = states.removeLast()
        if !fs.isEmpty {
            fs[0] = lastF; states[0] = lastS
            var p = 0
            let n = fs.count
            while true {
                let left = 2 * p + 1, right = 2 * p + 2
                var m = p
                if left < n, fs[left] < fs[m] { m = left }
                if right < n, fs[right] < fs[m] { m = right }
                if m == p { break }
                fs.swapAt(p, m); states.swapAt(p, m)
                p = m
            }
        }
        return top
    }
}

/// Binary min-heap keyed on f-score for the A* open set — replaces the old
/// linear scan so routing stays fast as the (cell × layer) state space grows.
/// Carries duplicate entries for a state; the search dedupes on pop with a
/// `visited` array (lazy deletion).
private struct MinHeap {
    private var fs: [Int] = []
    private var states: [Int] = []

    mutating func push(f: Int, state: Int) {
        fs.append(f); states.append(state)
        var c = fs.count - 1
        while c > 0 {
            let p = (c - 1) / 2
            if fs[p] <= fs[c] { break }
            fs.swapAt(p, c); states.swapAt(p, c)
            c = p
        }
    }

    mutating func pop() -> (f: Int, state: Int)? {
        guard !fs.isEmpty else { return nil }
        let top = (f: fs[0], state: states[0])
        let lastF = fs.removeLast(), lastS = states.removeLast()
        if !fs.isEmpty {
            fs[0] = lastF; states[0] = lastS
            var p = 0
            let n = fs.count
            while true {
                let left = 2 * p + 1, right = 2 * p + 2
                var m = p
                if left < n, fs[left] < fs[m] { m = left }
                if right < n, fs[right] < fs[m] { m = right }
                if m == p { break }
                fs.swapAt(p, m); states.swapAt(p, m)
                p = m
            }
        }
        return top
    }
}
