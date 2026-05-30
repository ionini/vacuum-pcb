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
                let halfLen = ManufacturingConstants.resistorFootprintLength / 2
                let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
                let transitions = ResistorGeometry.transitions(for: component.resistorSize ?? .medium)
                let local = ResistorGeometry.path(transitions: transitions, halfLen: halfLen, halfWid: halfWid)
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

/// A* over a (cell, layer) state space, where `layer` is a full plate + depth.
/// Same-layer 4-connected steps cost 1; a via costs `viaCost` (default 6) so
/// plain runs are preferred and the planner only changes layer when it pays
/// off. A via may either cross the silicone (top↔bottom at depth 0) or step
/// between adjacent depths inside one plate. Vias are forbidden where the
/// `noVias` mask is set (under component bodies) or where the destination
/// layer's cell is already occupied by another channel.
enum AStarML {
    static func run(
        grids: [Layer: OccupancyGrid],
        noVias: OccupancyGrid,
        layers: [Layer],
        from start: Point, fromLayer: Layer,
        to goal: Point, toLayer: Layer,
        viaCost: Int = 6
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

        func stateIdx(_ i: Int, _ j: Int, _ l: Int) -> Int { l * cells + j * cols + i }
        func heuristic(_ i: Int, _ j: Int, _ l: Int) -> Int {
            abs(i - gx) + abs(j - gy) + (l == goalLayer ? 0 : viaCost)
        }

        let total = cells * layerCount
        var gScore = Array(repeating: Int.max, count: total)
        var parent = Array(repeating: -1, count: total)
        var visited = Array(repeating: false, count: total)
        let startIdx = stateIdx(sx, sy, startLayer)
        let goalIdx = stateIdx(gx, gy, goalLayer)
        gScore[startIdx] = 0

        var open = MinHeap()
        open.push(f: heuristic(sx, sy, startLayer), state: startIdx)
        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        while let popped = open.pop() {
            let current = popped.state
            if visited[current] { continue }   // stale duplicate (lazy deletion)
            visited[current] = true
            if current == goalIdx {
                return reconstruct(parent: parent, goalIdx: goalIdx,
                                   cells: cells, cols: cols,
                                   layers: layers, gridForLayer: gridForLayer)
            }
            let l = current / cells
            let rem = current % cells
            let ci = rem % cols, cj = rem / cols

            // Same-layer 4-connected moves.
            let curGrid = gridForLayer[l]
            for (dx, dy) in neighbours {
                let ni = ci + dx, nj = cj + dy
                guard curGrid.inBounds(ni, nj) else { continue }
                let isGoalCell = (ni == gx && nj == gy && l == goalLayer)
                if curGrid.isBlocked(ni, nj), !isGoalCell { continue }
                let nIdx = stateIdx(ni, nj, l)
                let tentative = gScore[current] + 1
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = current
                    open.push(f: tentative + heuristic(ni, nj, l), state: nIdx)
                }
            }
            // Via to an adjacent layer at this cell. The destination cell must
            // be free (don't punch through an existing channel there) and the
            // cell must be outside the no-via mask (no bores under component
            // bodies — transistor dimples, resistors, port bores).
            if !noVias.isBlocked(ci, cj) {
                for nl in viaAdj[l] {
                    let isGoalCell = (ci == gx && cj == gy && nl == goalLayer)
                    if gridForLayer[nl].isBlocked(ci, cj), !isGoalCell { continue }
                    let nIdx = stateIdx(ci, cj, nl)
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
        parent: [Int], goalIdx: Int, cells: Int, cols: Int,
        layers: [Layer], gridForLayer: [OccupancyGrid]
    ) -> [(point: Point, layer: Layer)] {
        var result: [(Point, Layer)] = []
        var idx = goalIdx
        while idx >= 0 {
            let l = idx / cells
            let rem = idx % cells
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
