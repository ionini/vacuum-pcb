import Foundation

struct Placement: Codable, Hashable {
    var componentId: UUID
    var position: Point
    var rotation: Rotation
    /// Which plate the component's primary features live on. For ports/vacuumSource/atmVent,
    /// this is the plate the edge bore is drilled into. For a transistor it is the plate
    /// holding the dimple (gate). For a resistor it is the plate the serpentine sits in.
    var layer: Layer
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
}
