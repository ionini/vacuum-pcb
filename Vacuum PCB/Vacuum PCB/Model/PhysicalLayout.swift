import Foundation

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

    private enum CodingKeys: String, CodingKey {
        case componentId, position, rotation, layer, depth
    }

    init(componentId: UUID, position: Point, rotation: Rotation, layer: Plate, depth: Int = 0) {
        self.componentId = componentId
        self.position = position
        self.rotation = rotation
        self.layer = layer
        self.depth = max(0, depth)
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
