import Foundation

/// Anchors a connector placement to one edge of the plate's `boardOutline`.
/// `offsetAlongEdge` is in mm, measured from the edge's start corner
/// (south/north → from the west end at +X; east/west → from the south end
/// at +Y), to the **centre** of the connector's slot row. The placement's
/// `position` and `rotation` are derived from this anchor + the outline at
/// render / drag time; the stored `position` is a cache and shouldn't be
/// trusted independently of `edgeAnchor` for connector placements.
struct EdgeAnchor: Codable, Hashable {
    var edge: Edge
    var offsetAlongEdge: Double
}

extension EdgeAnchor {
    /// World-position of the connector's anchor (centre of the slot row,
    /// sitting on the plate edge — i.e., where the protrusion's inner face
    /// meets the plate). Combined with `edge.outwardRotation`, this is what
    /// the rest of the placement / footprint / CAD pipeline reads as the
    /// connector's pose.
    func worldPosition(in outline: Rect) -> Point {
        switch edge {
        case .south:
            return Point(x: outline.minX + offsetAlongEdge, y: outline.minY)
        case .north:
            return Point(x: outline.minX + offsetAlongEdge, y: outline.maxY)
        case .west:
            return Point(x: outline.minX, y: outline.minY + offsetAlongEdge)
        case .east:
            return Point(x: outline.maxX, y: outline.minY + offsetAlongEdge)
        }
    }

    /// Length of the edge this anchor lives on. Used by the drag UX and DRC
    /// to constrain `offsetAlongEdge` so the connector stays clear of both
    /// corners.
    func edgeLength(in outline: Rect) -> Double {
        switch edge {
        case .north, .south: return outline.size.width
        case .east, .west:   return outline.size.height
        }
    }

    /// Snap an arbitrary world point onto the nearest edge of `outline`,
    /// returning the matching `EdgeAnchor`. `minClearance` is the minimum
    /// distance (mm) the anchor's offset must keep from each corner —
    /// callers pass half the connector's row length plus one pin-pitch so
    /// the protrusion stays clear of the corner fillets. `gridSnap`, when
    /// > 0, rounds the offset to that pitch.
    static func snapping(
        worldPoint p: Point,
        to outline: Rect,
        minClearance: Double = 0,
        gridSnap: Double = 0
    ) -> EdgeAnchor {
        // Pick the closest of the 4 edges, breaking ties south > east >
        // north > west (arbitrary but deterministic).
        let dS = abs(p.y - outline.minY)
        let dN = abs(p.y - outline.maxY)
        let dW = abs(p.x - outline.minX)
        let dE = abs(p.x - outline.maxX)
        let candidates: [(Edge, Double, Double)] = [
            (.south, dS, p.x - outline.minX),
            (.east,  dE, p.y - outline.minY),
            (.north, dN, p.x - outline.minX),
            (.west,  dW, p.y - outline.minY),
        ]
        let chosen = candidates.min(by: { $0.1 < $1.1 })!
        var offset = chosen.2
        let len = (chosen.0 == .north || chosen.0 == .south)
            ? outline.size.width : outline.size.height
        if gridSnap > 0 {
            offset = (offset / gridSnap).rounded() * gridSnap
        }
        let clamp = max(0, minClearance)
        offset = max(clamp, min(len - clamp, offset))
        return EdgeAnchor(edge: chosen.0, offsetAlongEdge: offset)
    }
}

struct Placement: Codable, Hashable {
    var componentId: UUID
    var position: Point
    var rotation: Rotation
    /// Which plate the component's primary features live on. For ports/vacuumSource/atmVent,
    /// this is the plate the edge bore is drilled into. For a transistor it is the plate
    /// holding the dimple (gate). For a resistor it is the plate the serpentine sits in.
    var layer: Plate
    /// Channel-layer depth inside `layer`. Only resistors actually use this —
    /// they're pure tubes and can sit on any internal channel layer, so the
    /// physical-canvas F shortcut cycles them through every configured layer.
    /// For transistors and ports the depth is always 0 (their geometry — the
    /// dimple, drop bores, and edge bore — anchors at the silicone-facing
    /// surface), and writers can safely leave this at 0.
    var depth: Int
    /// Edge attachment for `.connector` placements. When non-nil the
    /// placement is constrained to a plate perimeter edge and its `position`
    /// / `rotation` are derived from the anchor at drag and render time.
    /// Always nil for non-connector kinds.
    var edgeAnchor: EdgeAnchor?

    private enum CodingKeys: String, CodingKey {
        case componentId, position, rotation, layer, depth, edgeAnchor
    }

    init(
        componentId: UUID,
        position: Point,
        rotation: Rotation,
        layer: Plate,
        depth: Int = 0,
        edgeAnchor: EdgeAnchor? = nil
    ) {
        self.componentId = componentId
        self.position = position
        self.rotation = rotation
        self.layer = layer
        self.depth = max(0, depth)
        self.edgeAnchor = edgeAnchor
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        componentId = try c.decode(UUID.self, forKey: .componentId)
        position = try c.decode(Point.self, forKey: .position)
        rotation = try c.decode(Rotation.self, forKey: .rotation)
        // Older files encoded `layer` as a single string ("top" / "bottom")
        // and predate per-placement depth — default depth to 0 there.
        layer = try c.decode(Plate.self, forKey: .layer)
        depth = max(0, try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0)
        edgeAnchor = try c.decodeIfPresent(EdgeAnchor.self, forKey: .edgeAnchor)
    }
}

enum WaypointKind: String, Codable, CaseIterable {
    case point
    case via
}

struct Waypoint: Codable, Hashable {
    var position: Point
    var kind: WaypointKind

    init(position: Point, kind: WaypointKind = .point) {
        self.position = position
        self.kind = kind
    }
}

struct Segment: Codable, Hashable {
    var waypoints: [Waypoint]
    var layer: Layer
}

struct Route: Codable, Hashable {
    var netId: UUID
    var segments: [Segment]
}

extension Segment {
    /// Total length (mm) of the waypoint polyline.
    var polylineLength: Double {
        let pts = waypoints.map(\.position)
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            total += hypot(pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y)
        }
        return total
    }

    /// World point at arc-length `offset` along the polyline, clamped to
    /// `[0, polylineLength]`. The bead-on-rail evaluation for a test point.
    func point(atOffset offset: Double) -> Point {
        let pts = waypoints.map(\.position)
        guard let first = pts.first else { return .zero }
        guard pts.count >= 2 else { return first }
        var remaining = max(0, offset)
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let len = hypot(b.x - a.x, b.y - a.y)
            if len <= 0 { continue }
            if remaining <= len {
                let t = remaining / len
                return Point(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            }
            remaining -= len
        }
        return pts.last ?? first
    }

    /// Project `p` onto the polyline; returns the closest point and its
    /// arc-length from the segment start. Inverse of `point(atOffset:)`, used
    /// to drop and drag a test point along the rail.
    func projection(of p: Point) -> (point: Point, offset: Double) {
        let pts = waypoints.map(\.position)
        guard pts.count >= 2 else { return (pts.first ?? .zero, 0) }
        var best: (point: Point, offset: Double, dist: Double)?
        var base = 0.0
        for i in 0..<(pts.count - 1) {
            let a = pts[i], b = pts[i + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let len2 = dx * dx + dy * dy
            let t: Double = len2 <= 0
                ? 0
                : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
            let proj = Point(x: a.x + dx * t, y: a.y + dy * t)
            let d = hypot(p.x - proj.x, p.y - proj.y)
            let segLen = len2.squareRoot()
            if best == nil || d < best!.dist {
                best = (proj, base + segLen * t, d)
            }
            base += segLen
        }
        return (best!.point, best!.offset)
    }
}

/// A **testing point**: a probe/gauge tap that bores vertically from a route
/// segment's channel out to the plate's outer face (the surface opposite the
/// silicone sheet) — the same tapered socket geometry as an edge port, but
/// pointing straight out instead of sideways to a board edge.
///
/// Physical-view-only: it has no schematic symbol or logic pin. It rides a
/// single route segment like a bead on a rail (`segmentIndex` + arc-length
/// `offset`) and is logically inert in simulation — it only surfaces as a
/// read-only pressure probe on the net it taps.
struct TestPoint: Codable, Hashable, Identifiable {
    var id: UUID
    /// User-editable designator ("TP1"…). Cosmetic — stripped from the
    /// document geometry hashes so renaming never churns library snapshots.
    var name: String
    /// The net whose route this point taps (drives the schematic annotation
    /// and the DRC / probe labels).
    var netId: UUID
    /// Which segment of `netId`'s route the bead rides — the XY rail.
    var segmentIndex: Int
    /// Arc-length (mm) of the bead along that segment's waypoint polyline.
    var offset: Double
    /// Plate the bore exits. Fixed at creation (= the clicked segment's plate);
    /// `F` never flips it, so the hole always opens on the same outer face as
    /// the tapped route.
    var plate: Plate
    /// Channel depth the bore starts from inside `plate`. Initialised to the
    /// clicked segment's depth, then cycled by `F` within the plate's layers;
    /// may differ from the ridden segment's depth after `F`.
    var depth: Int
    /// Cached world XY. Treated as derived — consumers resolve the live
    /// position from the ridden segment via `PhysicalLayout.testPointWorld(_:)`
    /// and fall back to this only when the route has gone missing.
    var position: Point

    init(id: UUID = UUID(), name: String, netId: UUID, segmentIndex: Int,
         offset: Double, plate: Plate, depth: Int, position: Point) {
        self.id = id
        self.name = name
        self.netId = netId
        self.segmentIndex = segmentIndex
        self.offset = max(0, offset)
        self.plate = plate
        self.depth = max(0, depth)
        self.position = position
    }
}

struct PhysicalLayout: Codable, Hashable {
    var placements: [Placement]
    var routes: [Route]
    var boardOutline: Rect
    /// How many channel layers exist in the top plate. Depth 0 is the
    /// silicone-facing layer (always present); higher depths stack outward
    /// into the plate. Default 1 = single channel layer (legacy behaviour).
    var topLayers: Int
    /// Same as `topLayers`, but for the bottom plate.
    var bottomLayers: Int
    /// Physical-view testing points (probe taps to the outer surface). New in
    /// schema v10; omitted from the encoding when empty so pre-v10 docs
    /// round-trip byte-identically.
    var testPoints: [TestPoint]

    private enum CodingKeys: String, CodingKey {
        case placements, routes, boardOutline, topLayers, bottomLayers, testPoints
    }

    init(
        placements: [Placement],
        routes: [Route],
        boardOutline: Rect,
        topLayers: Int = 1,
        bottomLayers: Int = 1,
        testPoints: [TestPoint] = []
    ) {
        self.placements = placements
        self.routes = routes
        self.boardOutline = boardOutline
        self.topLayers = max(1, topLayers)
        self.bottomLayers = max(1, bottomLayers)
        self.testPoints = testPoints
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placements = try c.decode([Placement].self, forKey: .placements)
        routes = try c.decode([Route].self, forKey: .routes)
        boardOutline = try c.decode(Rect.self, forKey: .boardOutline)
        // Older files predate multi-layer; default both to 1.
        topLayers = max(1, try c.decodeIfPresent(Int.self, forKey: .topLayers) ?? 1)
        bottomLayers = max(1, try c.decodeIfPresent(Int.self, forKey: .bottomLayers) ?? 1)
        // Older files predate testing points.
        testPoints = try c.decodeIfPresent([TestPoint].self, forKey: .testPoints) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(placements, forKey: .placements)
        try c.encode(routes, forKey: .routes)
        try c.encode(boardOutline, forKey: .boardOutline)
        try c.encode(topLayers, forKey: .topLayers)
        try c.encode(bottomLayers, forKey: .bottomLayers)
        // Omit when empty so documents without testing points (every doc
        // written before schema v10) encode byte-identically to before.
        if !testPoints.isEmpty {
            try c.encode(testPoints, forKey: .testPoints)
        }
    }

    /// Number of channel layers configured for a given plate.
    func layerCount(for plate: Plate) -> Int {
        switch plate {
        case .top: return topLayers
        case .bottom: return bottomLayers
        }
    }

    /// All in-use `Layer` values for a given plate, in depth order.
    func layers(in plate: Plate) -> [Layer] {
        (0..<layerCount(for: plate)).map { Layer(plate: plate, depth: $0) }
    }

    // MARK: - Testing points

    /// The route segment a test point rides, if it still exists. Test points
    /// are addressed like route selections — by `(netId, segmentIndex)` into
    /// the net's route (see `PhysicalSelection.RouteSegmentRef`).
    func testPointSegment(_ tp: TestPoint) -> Segment? {
        guard let route = routes.first(where: { $0.netId == tp.netId }),
              tp.segmentIndex >= 0, tp.segmentIndex < route.segments.count
        else { return nil }
        return route.segments[tp.segmentIndex]
    }

    /// Live world XY of a test point, resolved from the segment it rides.
    /// `nil` when its route/segment no longer exists (the point should be
    /// pruned). Consumers use this rather than the cached `position` so a
    /// dragged/edited route carries its test points along automatically.
    func testPointWorld(_ tp: TestPoint) -> Point? {
        testPointSegment(tp)?.point(atOffset: tp.offset)
    }

    /// The `Layer` a test point bores from (its fixed plate + `F`-cycled depth).
    func testPointLayer(_ tp: TestPoint) -> Layer {
        Layer(plate: tp.plate, depth: min(tp.depth, max(0, layerCount(for: tp.plate) - 1)))
    }

    /// Drop orphaned test points whose ridden route/segment has been deleted.
    mutating func pruneTestPoints() {
        let kept = testPoints.filter { testPointSegment($0) != nil }
        if kept.count != testPoints.count { testPoints = kept }
    }

    /// First free `"TP\(n)"` designator (test points aren't in `logic`, so
    /// this mirrors `LogicGraph.nextLabel` locally).
    func nextTestPointName() -> String {
        let used = Set(testPoints.map(\.name))
        var n = 1
        while used.contains("TP\(n)") { n += 1 }
        return "TP\(n)"
    }

    /// Via XYs that pair a T0 segment with a B0 segment on the *same net* —
    /// the only via kind that actually punches through the silicone sheet
    /// sandwiched between the plates. Same-plate vias (a route stepping
    /// between depths inside one plate) never cross silicone and are skipped.
    ///
    /// Used by the silicone-sheet view overlay and the stencil CAD pass.
    /// Matching uses a 0.05 mm tolerance, the same the rest of the
    /// codebase uses for paired-via bookkeeping.
    func crossSiliconeViaPositions() -> [Point] {
        let eps = 0.05
        var result: [Point] = []
        for route in routes {
            var topPositions: [Point] = []
            var bottomPositions: [Point] = []
            for segment in route.segments where segment.layer.depth == 0 {
                for wp in segment.waypoints where wp.kind == .via {
                    switch segment.layer.plate {
                    case .top:    topPositions.append(wp.position)
                    case .bottom: bottomPositions.append(wp.position)
                    }
                }
            }
            for p in topPositions {
                let matched = bottomPositions.contains {
                    abs($0.x - p.x) < eps && abs($0.y - p.y) < eps
                }
                guard matched else { continue }
                let alreadyAdded = result.contains {
                    abs($0.x - p.x) < eps && abs($0.y - p.y) < eps
                }
                if !alreadyAdded { result.append(p) }
            }
        }
        return result
    }

    /// Every XY on `netId` where a route segment carries a `.via` waypoint,
    /// paired with the set of layers that meet there. A group spanning **two
    /// or more layers** is a real drilled bore: `PlateBuilder` only cuts a via
    /// when ≥2 layers coincide, so that's also the only place two layers may
    /// be treated as electrically joined. A single-layer group is an "orphan"
    /// via that connects nothing (DRC reports it as `orphanVia`). Grouped per
    /// net so two nets that happen to share an XY don't look merged. XY matched
    /// within 0.05 mm — the via-bookkeeping tolerance used across the codebase.
    ///
    /// Shared truth for the via-pairing rule that `PlateBuilder` (where it cuts
    /// bores) and `Ratsnest`/`DRC` (where they judge connectivity) must agree
    /// on — they diverged once and that's exactly how an orphan via slipped
    /// past the ratsnest.
    func viaLayerGroups(netId: UUID) -> [(position: Point, layers: Set<Layer>)] {
        let eps = 0.05
        var groups: [(position: Point, layers: Set<Layer>)] = []
        for route in routes where route.netId == netId {
            for segment in route.segments {
                for wp in segment.waypoints where wp.kind == .via {
                    if let i = groups.firstIndex(where: {
                        abs($0.position.x - wp.position.x) < eps && abs($0.position.y - wp.position.y) < eps
                    }) {
                        groups[i].layers.insert(segment.layer)
                    } else {
                        groups.append((position: wp.position, layers: [segment.layer]))
                    }
                }
            }
        }
        return groups
    }
}
