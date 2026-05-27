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

    private enum CodingKeys: String, CodingKey {
        case placements, routes, boardOutline, topLayers, bottomLayers
    }

    init(
        placements: [Placement],
        routes: [Route],
        boardOutline: Rect,
        topLayers: Int = 1,
        bottomLayers: Int = 1
    ) {
        self.placements = placements
        self.routes = routes
        self.boardOutline = boardOutline
        self.topLayers = max(1, topLayers)
        self.bottomLayers = max(1, bottomLayers)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        placements = try c.decode([Placement].self, forKey: .placements)
        routes = try c.decode([Route].self, forKey: .routes)
        boardOutline = try c.decode(Rect.self, forKey: .boardOutline)
        // Older files predate multi-layer; default both to 1.
        topLayers = max(1, try c.decodeIfPresent(Int.self, forKey: .topLayers) ?? 1)
        bottomLayers = max(1, try c.decodeIfPresent(Int.self, forKey: .bottomLayers) ?? 1)
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
}
