import Foundation

struct Placement: Codable, Hashable {
    var componentId: UUID
    var position: Point
    var rotation: Rotation
    /// Which plate the component's primary features live on. For ports/vacuumSource/atmVent,
    /// this is the plate the edge bore is drilled into. For a transistor it is the plate
    /// holding the dimple (gate). For a resistor it is the plate the serpentine sits in.
    ///
    /// Components are always anchored to the silicone-facing surface (depth 0)
    /// of their plate; only routes get a depth.
    var layer: Plate

    private enum CodingKeys: String, CodingKey {
        case componentId, position, rotation, layer
    }

    init(componentId: UUID, position: Point, rotation: Rotation, layer: Plate) {
        self.componentId = componentId
        self.position = position
        self.rotation = rotation
        self.layer = layer
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        componentId = try c.decode(UUID.self, forKey: .componentId)
        position = try c.decode(Point.self, forKey: .position)
        rotation = try c.decode(Rotation.self, forKey: .rotation)
        // Older files encoded `layer` as a single string ("top" / "bottom").
        // New files use the same Plate enum (still a single string), so the
        // standard decode works for both.
        layer = try c.decode(Plate.self, forKey: .layer)
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
}
