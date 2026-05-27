import Foundation

struct Point: Codable, Hashable {
    var x: Double
    var y: Double

    static let zero = Point(x: 0, y: 0)
}

struct Rect: Codable, Hashable {
    var origin: Point
    var size: Size

    var minX: Double { origin.x }
    var minY: Double { origin.y }
    var maxX: Double { origin.x + size.width }
    var maxY: Double { origin.y + size.height }
}

struct Size: Codable, Hashable {
    var width: Double
    var height: Double
}

enum Rotation: String, Codable, CaseIterable {
    case r0, r90, r180, r270

    var radians: Double {
        switch self {
        case .r0: return 0
        case .r90: return .pi / 2
        case .r180: return .pi
        case .r270: return 3 * .pi / 2
        }
    }
}

/// Which of the two plates a feature lives on. Components always sit on a
/// specific plate at the silicone-facing surface (depth 0); routes can sit
/// on any depth within a plate, identified by `Layer` below.
enum Plate: String, Codable, CaseIterable, Hashable {
    case top, bottom

    var opposite: Plate { self == .top ? .bottom : .top }

    /// Single-letter prefix used in compact layer labels ("T", "B").
    var uiPrefix: String { self == .top ? "T" : "B" }
}

/// Which side of a rectangular `boardOutline` a connector is attached to.
/// `north` is +Y, `south` is -Y, `east` is +X, `west` is -X. Used by
/// `EdgeAnchor` on `Placement` to constrain connector placements to the
/// plate perimeter and to drive the protrusion's outward direction in the
/// CAD pipeline.
enum Edge: String, Codable, CaseIterable, Hashable {
    case north, south, east, west

    /// Unit vector pointing outward from the plate along this edge.
    var outwardNormal: Point {
        switch self {
        case .north: return Point(x: 0, y: 1)
        case .south: return Point(x: 0, y: -1)
        case .east:  return Point(x: 1, y: 0)
        case .west:  return Point(x: -1, y: 0)
        }
    }

    /// Unit vector running along this edge in the +offsetAlongEdge direction.
    /// For horizontal edges (north/south) offset increases with +X; for
    /// vertical edges (east/west) offset increases with +Y.
    var tangent: Point {
        switch self {
        case .north, .south: return Point(x: 1, y: 0)
        case .east, .west:   return Point(x: 0, y: 1)
        }
    }

    /// Rotation that points a connector footprint outward along this edge.
    /// Footprints are authored at `r0` with the outward direction along +X
    /// (east); the other three edges are 90° rotations of that.
    var outwardRotation: Rotation {
        switch self {
        case .east:  return .r0
        case .north: return .r90
        case .west:  return .r180
        case .south: return .r270
        }
    }
}

/// Identifies one channel layer in the assembly. `plate` picks which plate
/// the layer lives in; `depth` counts outward from the silicone-facing
/// surface (0 = the silicone-facing channel — the only depth that exists in
/// a single-layer plate). Multi-layer plates add `depth = 1, 2, …` stacking
/// outward into the plate's interior.
///
/// Backward compatibility: `Layer` decodes from the old `String` form
/// ("top" / "bottom") as `(plate: <decoded>, depth: 0)`, so every existing
/// `.vpcb` decodes unchanged.
struct Layer: Hashable, Codable, Sendable {
    var plate: Plate
    var depth: Int

    init(plate: Plate, depth: Int = 0) {
        self.plate = plate
        self.depth = depth
    }

    static let top = Layer(plate: .top, depth: 0)
    static let bottom = Layer(plate: .bottom, depth: 0)

    private enum CodingKeys: String, CodingKey { case plate, depth }

    init(from decoder: Decoder) throws {
        // Try the legacy single-string format first ("top" / "bottom"); fall
        // back to the new keyed container if that fails.
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self),
           let plate = Plate(rawValue: raw) {
            self.plate = plate
            self.depth = 0
            return
        }
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.plate = try c.decode(Plate.self, forKey: .plate)
        self.depth = try c.decodeIfPresent(Int.self, forKey: .depth) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(plate, forKey: .plate)
        try c.encode(depth, forKey: .depth)
    }

    /// Compact label used in pickers and DRC summaries — "T0", "B1", etc.
    var uiLabel: String {
        let prefix = plate == .top ? "T" : "B"
        return "\(prefix)\(depth)"
    }
}
