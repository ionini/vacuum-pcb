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

        var top = OccupancyGrid(outline: outline, pitch: pitch)
        var bottom = OccupancyGrid(outline: outline, pitch: pitch)

        // Clearance halo: stamp `halo` cells around each centerline cell so
        // a parallel route can't sit closer than `minChannelSpacing` (cell-
        // to-cell distance). Halo of N cells leaves at least N+1 cells of
        // separation between centerlines → (N+1) × pitch mm.
        let halo = max(1, Int((doc.manufacturing.minChannelSpacing / pitch).rounded(.up)) - 1)

        // 1. Seed occupancy with already-drawn route polylines.
        for route in doc.physical.routes {
            for segment in route.segments {
                let pts = segment.waypoints.map(\.position)
                guard pts.count >= 2 else { continue }
                let grid = segment.layer == .top ? top : bottom
                for i in 0..<(pts.count - 1) {
                    grid.markLine(pts[i], pts[i + 1], halo: halo)
                }
                segment.layer == .top ? (top = grid) : (bottom = grid)
            }
        }
        // 2. Seed with resistor serpentines so they don't get crossed.
        seedComponentFeatures(in: doc, top: &top, bottom: &bottom, halo: halo)
        // 3. Clear a tight neighbourhood around every placed pin so A* can
        //    always enter/exit pin cells, even if a previous route's halo
        //    stamped over them. Pins themselves don't count as obstacles
        //    here — they're attachment points, not channels.
        clearPinNeighborhoods(in: doc, top: top, bottom: bottom)
        // 4. Component exclusion zones block via insertion. Routes can still
        //    pass through (the cells aren't marked on the per-layer grids
        //    unless something else put them there), but a via punching the
        //    plate inside a transistor's dimple or a resistor's body would
        //    wreck the part — explicitly disallow that.
        let noVias = OccupancyGrid(outline: outline, pitch: pitch)
        seedNoViaZones(in: doc, grid: noVias)

        var planned: [(netId: UUID, segment: Segment)] = []

        // 3. Route nets in a stable order. For each net, build pin positions
        //    per layer and an MST over placed pins, then try A* on each
        //    MST edge whose endpoints share a layer.
        for net in doc.logic.nets {
            let placed = placedPins(for: net, in: doc)
            guard placed.count >= 2 else { continue }

            // Skip net pairs already electrically connected via existing routes.
            let alreadyConnected = connectivityMap(net: net, in: doc, pinPositions: placed.map(\.position))

            for edge in mstEdges(placed.map(\.position)) {
                let a = placed[edge.i]
                let b = placed[edge.j]
                if alreadyConnected.same(edge.i, edge.j) { continue }
                guard let path = AStar2L.run(
                    topGrid: top, bottomGrid: bottom, noVias: noVias,
                    from: a.position, fromPlate: a.plate,
                    to: b.position, toPlate: b.plate
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
                    // Mark the new segment in the appropriate grid so
                    // subsequent routes (in this run) avoid it.
                    let pts = seg.waypoints.map(\.position)
                    let grid = seg.layer.plate == .top ? top : bottom
                    for i in 0..<(pts.count - 1) {
                        grid.markLine(pts[i], pts[i + 1], halo: halo)
                    }
                }
            }
        }

        return planned
    }

    /// Splits a two-layer A* path into one Segment per contiguous same-layer
    /// run. Cells where the path changes layer become matching `.via`
    /// waypoints — one at the end of the outgoing segment, one at the start
    /// of the incoming segment, both at the same XY. Same model the manual
    /// V-key routing uses.
    private static func pathToSegments(_ path: [(point: Point, plate: Plate)]) -> [Segment] {
        guard !path.isEmpty else { return [] }
        var segments: [Segment] = []
        var currentPlate = path[0].plate
        var currentWaypoints: [Waypoint] = [Waypoint(position: path[0].point, kind: .point)]
        for i in 1..<path.count {
            let prev = path[i - 1]
            let cur = path[i]
            if cur.plate != prev.plate {
                // Replace the trailing waypoint of the current segment with
                // a .via, then start a fresh segment on the new plate also
                // beginning at this shared XY as a .via.
                if let last = currentWaypoints.last {
                    currentWaypoints[currentWaypoints.count - 1] =
                        Waypoint(position: last.position, kind: .via)
                }
                segments.append(Segment(
                    waypoints: compactWaypoints(currentWaypoints),
                    layer: Layer(plate: currentPlate, depth: 0)
                ))
                currentPlate = cur.plate
                currentWaypoints = [Waypoint(position: cur.point, kind: .via)]
            } else {
                currentWaypoints.append(Waypoint(position: cur.point, kind: .point))
            }
        }
        segments.append(Segment(
            waypoints: compactWaypoints(currentWaypoints),
            layer: Layer(plate: currentPlate, depth: 0)
        ))
        // Drop any degenerate single-waypoint segments that would survive a
        // zero-length plate change at the end of the path.
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
        let plate: Plate
    }

    private static func placedPins(for net: Net, in doc: CircuitDocument) -> [PlacedPin] {
        var out: [PlacedPin] = []
        for ref in net.pins {
            guard let placement = doc.physical.placements.first(where: { $0.componentId == ref.componentId }),
                  let component = doc.logic.components.first(where: { $0.id == ref.componentId }),
                  let fp = component.footprint(doc.manufacturing).pin(ref.pinKey)
            else { continue }
            out.append(PlacedPin(
                position: placement.worldPosition(of: fp),
                plate: placement.resolvedPlate(of: fp)
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

    /// Drop redundant collinear waypoints from an A* result. The grid path
    /// emits one waypoint per cell; we keep only direction-change vertices.
    private static func compactPolyline(_ pts: [Point]) -> [Point] {
        guard pts.count > 2 else { return pts }
        var out: [Point] = [pts[0]]
        for i in 1..<(pts.count - 1) {
            let a = out.last!
            let b = pts[i]
            let c = pts[i + 1]
            let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
            if abs(cross) > 0.001 {
                out.append(b)
            }
        }
        out.append(pts.last!)
        return out
    }

    /// Stamp resistor serpentines and port bores into the occupancy grid so
    /// auto-routes don't drive through them.
    private static func seedComponentFeatures(
        in doc: CircuitDocument, top: inout OccupancyGrid, bottom: inout OccupancyGrid, halo: Int
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
                let grid = placement.layer == .top ? top : bottom
                for i in 0..<(world.count - 1) {
                    grid.markLine(world[i], world[i + 1], halo: halo)
                }
                placement.layer == .top ? (top = grid) : (bottom = grid)
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
        in doc: CircuitDocument, top: OccupancyGrid, bottom: OccupancyGrid
    ) {
        for placement in doc.physical.placements {
            guard let component = doc.logic.components.first(where: { $0.id == placement.componentId })
            else { continue }
            for fpPin in component.footprint(doc.manufacturing).pins {
                let world = placement.worldPosition(of: fpPin)
                let plate = placement.resolvedPlate(of: fpPin)
                let grid = plate == .top ? top : bottom
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
            let rect = component.footprint(doc.manufacturing).exclusionRect
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

// MARK: - Two-plate A*

/// A* over a (cell, plate) state space, so the planner can drop vias when
/// the cheaper path needs the other plate. Same-plate step costs 1; a plate
/// change (via) costs `viaCost` (default 6) so plain runs are preferred.
/// Auto-routing currently only uses depth-0 channels — the caller wraps the
/// returned plates into `Layer(plate:, depth: 0)` segments.
enum AStar2L {
    static func run(
        topGrid: OccupancyGrid, bottomGrid: OccupancyGrid,
        noVias: OccupancyGrid,
        from start: Point, fromPlate startPlate: Plate,
        to goal: Point, toPlate goalPlate: Plate,
        viaCost: Int = 6
    ) -> [(point: Point, plate: Plate)]? {
        // Both grids share dims; pick either for coordinate conversion.
        let (sx, sy) = topGrid.toGrid(start)
        let (gx, gy) = topGrid.toGrid(goal)
        guard topGrid.inBounds(sx, sy), topGrid.inBounds(gx, gy) else { return nil }

        let cols = topGrid.cols
        let total = cols * topGrid.rows
        func gridFor(_ plate: Plate) -> OccupancyGrid {
            plate == .top ? topGrid : bottomGrid
        }
        func stateIdx(_ i: Int, _ j: Int, _ plate: Plate) -> Int {
            (plate == .top ? 0 : 1) * total + j * cols + i
        }
        func unpack(_ idx: Int) -> (i: Int, j: Int, plate: Plate) {
            let plate: Plate = idx < total ? .top : .bottom
            let rem = idx % total
            return (rem % cols, rem / cols, plate)
        }
        func heuristic(_ i: Int, _ j: Int, _ plate: Plate) -> Int {
            abs(i - gx) + abs(j - gy) + (plate == goalPlate ? 0 : viaCost)
        }

        struct Node: Comparable {
            let f: Int
            let stateIdx: Int
            static func < (l: Node, r: Node) -> Bool { l.f < r.f }
            static func == (l: Node, r: Node) -> Bool { l.f == r.f }
        }

        var gScore = Array(repeating: Int.max, count: total * 2)
        var parent = Array(repeating: -1, count: total * 2)
        let startIdx = stateIdx(sx, sy, startPlate)
        let goalIdx = stateIdx(gx, gy, goalPlate)
        gScore[startIdx] = 0
        var open: [Node] = [Node(f: heuristic(sx, sy, startPlate), stateIdx: startIdx)]

        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        while !open.isEmpty {
            var minIdx = 0
            for k in 1..<open.count where open[k] < open[minIdx] { minIdx = k }
            let current = open.remove(at: minIdx)
            if current.stateIdx == goalIdx {
                return reconstruct(parent: parent, goalIdx: goalIdx, total: total,
                                   cols: cols, topGrid: topGrid, bottomGrid: bottomGrid)
            }
            let (ci, cj, cplate) = unpack(current.stateIdx)
            // Same-plate 4-connected moves.
            let curGrid = gridFor(cplate)
            for (dx, dy) in neighbours {
                let ni = ci + dx, nj = cj + dy
                guard curGrid.inBounds(ni, nj) else { continue }
                let isGoalCell = (ni == gx && nj == gy && cplate == goalPlate)
                if curGrid.isBlocked(ni, nj), !isGoalCell { continue }
                let tentative = gScore[current.stateIdx] + 1
                let nIdx = stateIdx(ni, nj, cplate)
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = current.stateIdx
                    open.append(Node(f: tentative + heuristic(ni, nj, cplate), stateIdx: nIdx))
                }
            }
            // Plate change at this cell. Two extra checks:
            //   * the cell on the *other* plate must be free (otherwise we'd
            //     punch a via through an existing route on that side),
            //   * the no-via mask must not have flagged this cell — vias
            //     under component bodies (transistor dimples, resistors,
            //     port bores) would compromise the part.
            let otherPlate: Plate = cplate.opposite
            let isGoalCellOnOther = (ci == gx && cj == gy && otherPlate == goalPlate)
            if !noVias.isBlocked(ci, cj),
               !gridFor(otherPlate).isBlocked(ci, cj) || isGoalCellOnOther {
                let nIdx = stateIdx(ci, cj, otherPlate)
                let tentative = gScore[current.stateIdx] + viaCost
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = current.stateIdx
                    open.append(Node(f: tentative + heuristic(ci, cj, otherPlate), stateIdx: nIdx))
                }
            }
        }
        return nil
    }

    private static func reconstruct(
        parent: [Int], goalIdx: Int, total: Int, cols: Int,
        topGrid: OccupancyGrid, bottomGrid: OccupancyGrid
    ) -> [(point: Point, plate: Plate)] {
        var result: [(Point, Plate)] = []
        var idx = goalIdx
        while idx >= 0 {
            let plate: Plate = idx < total ? .top : .bottom
            let rem = idx % total
            let i = rem % cols
            let j = rem / cols
            let grid = plate == .top ? topGrid : bottomGrid
            result.append((grid.toWorld(i, j), plate))
            let next = parent[idx]
            if next == idx || next < 0 { break }
            idx = next
        }
        return result.reversed().map { (point: $0.0, plate: $0.1) }
    }
}

// MARK: - A*

enum AStar {
    /// 4-connected grid A* between two world points. `pitch` and `outline`
    /// drive coordinate conversion. Returns world-coordinate waypoints in
    /// the result (one per grid cell). Caller compacts.
    static func run(
        grid: OccupancyGrid, from a: Point, to b: Point, pitch: Double, outline: Rect
    ) -> [Point]? {
        let (sx, sy) = grid.toGrid(a)
        let (gx, gy) = grid.toGrid(b)
        guard grid.inBounds(sx, sy), grid.inBounds(gx, gy) else { return nil }
        if sx == gx && sy == gy { return [a, b] }

        struct Node: Comparable {
            let f: Int
            let i: Int
            let j: Int
            static func < (l: Node, r: Node) -> Bool { l.f < r.f }
            static func == (l: Node, r: Node) -> Bool { l.f == r.f }
        }

        let cols = grid.cols, rows = grid.rows
        var gScore = Array(repeating: Int.max, count: cols * rows)
        var parent = Array(repeating: -1, count: cols * rows)
        var open: [Node] = []
        let startIdx = sy * cols + sx
        gScore[startIdx] = 0
        open.append(Node(f: heuristic(sx, sy, gx, gy), i: sx, j: sy))

        let neighbours = [(1, 0), (-1, 0), (0, 1), (0, -1)]

        while !open.isEmpty {
            // Linear-scan min — fine for the board sizes we deal with (few
            // thousand cells max). Swap for a real priority queue if it
            // becomes a bottleneck.
            var minIdx = 0
            for k in 1..<open.count where open[k] < open[minIdx] { minIdx = k }
            let current = open.remove(at: minIdx)
            if current.i == gx && current.j == gy {
                return reconstruct(parent: parent, cols: cols, endX: gx, endY: gy, grid: grid)
            }
            let curIdx = current.j * cols + current.i
            for (dx, dy) in neighbours {
                let nx = current.i + dx, ny = current.j + dy
                guard grid.inBounds(nx, ny) else { continue }
                // The goal cell is always considered free for THIS route
                // (it's the destination pin, even though it might be marked
                // as a pin obstacle for other nets).
                if grid.isBlocked(nx, ny), !(nx == gx && ny == gy) { continue }
                let tentative = gScore[curIdx] + 1
                let nIdx = ny * cols + nx
                if tentative < gScore[nIdx] {
                    gScore[nIdx] = tentative
                    parent[nIdx] = curIdx
                    let f = tentative + heuristic(nx, ny, gx, gy)
                    open.append(Node(f: f, i: nx, j: ny))
                }
            }
        }
        return nil
    }

    private static func heuristic(_ x: Int, _ y: Int, _ gx: Int, _ gy: Int) -> Int {
        abs(x - gx) + abs(y - gy)
    }

    private static func reconstruct(
        parent: [Int], cols: Int, endX: Int, endY: Int, grid: OccupancyGrid
    ) -> [Point] {
        var path: [Point] = []
        var cur = endY * cols + endX
        while cur >= 0 {
            let i = cur % cols
            let j = cur / cols
            path.append(grid.toWorld(i, j))
            let next = parent[cur]
            if next == cur { break }
            cur = next
        }
        return path.reversed()
    }
}
