import Foundation

/// Multi-selection on the physical canvas.
///
/// Tracks any number of placements at once (so a marquee drag can grab a
/// whole subcircuit) plus an optional single route segment — only one route
/// segment is selectable at a time because the waypoint-drag handles only
/// make sense for one segment, and ⌫ on a route segment removes just that
/// one. Pin handles aren't selectable; they participate in routing only.
struct PhysicalSelection: Hashable {
    var placements: Set<UUID> = []
    var routeSegment: RouteSegmentRef? = nil
    /// Additional route waypoints picked up by the marquee (or future
    /// Cmd-clicks on handles). These ride along when the selection is
    /// dragged, so multi-select can grab a subcircuit *with* its interior
    /// route bends and move it all as one piece.
    var waypoints: Set<RouteWaypointAddress> = []

    struct RouteSegmentRef: Hashable {
        let netId: UUID
        let segmentIndex: Int
    }

    static let none = PhysicalSelection()

    var isEmpty: Bool { placements.isEmpty && routeSegment == nil && waypoints.isEmpty }

    /// Convenience: when exactly one placement is selected (and nothing else),
    /// the legacy single-component code paths (rotate, flip layer, inspector
    /// title) treat that as "the selected placement". With multi-select we
    /// gate those operations on placements.count == 1.
    var singlePlacement: UUID? {
        guard routeSegment == nil, placements.count == 1 else { return nil }
        return placements.first
    }

    /// Used to gate the hidden Delete shortcut — see SchematicSelection for
    /// the rationale.
    var isDeletable: Bool { !isEmpty }

    func contains(placement id: UUID) -> Bool { placements.contains(id) }
    func contains(routeSegment ref: RouteSegmentRef) -> Bool { routeSegment == ref }

    static func placement(_ id: UUID) -> PhysicalSelection {
        PhysicalSelection(placements: [id])
    }

    static func routeSegment(netId: UUID, segmentIndex: Int) -> PhysicalSelection {
        PhysicalSelection(routeSegment: RouteSegmentRef(netId: netId, segmentIndex: segmentIndex))
    }
}

/// State of the click-pin → click-waypoints → click-pin routing interaction.
/// `waypoints` is the in-progress polyline (world mm). The pinning starts on
/// the first pin, so `waypoints[0]` is the first pin's world location.
///
/// `startsAtVia` marks segments that picked up routing after the user dropped
/// a via — the first waypoint then needs `kind: .via` when committed so the
/// CAD pipeline knows to drill the cross-plate bore. Plain pin-started
/// routes leave it `false`.
enum RoutingState: Hashable {
    case idle
    case routing(netId: UUID, waypoints: [Point], layer: Layer, startsAtVia: Bool)

    var inProgress: Bool {
        if case .routing = self { return true }
        return false
    }
}

/// Which layers are visible in the physical editor. With multi-layer plates
/// this generalises to either "everything", "everything on one plate", or an
/// explicit pick of layers (the per-layer pills with multi-select).
enum LayerVisibility: Hashable {
    case all
    case plateOnly(Plate)
    case explicit(Set<Layer>)

    /// Legacy three-pill aliases. Existing code uses these as the canonical
    /// values; UI extensions can swap in the multi-select variant later.
    static let both: LayerVisibility = .all
    static let topOnly: LayerVisibility = .plateOnly(.top)
    static let bottomOnly: LayerVisibility = .plateOnly(.bottom)

    func contains(_ layer: Layer) -> Bool {
        switch self {
        case .all: return true
        case .plateOnly(let plate): return layer.plate == plate
        case .explicit(let set): return set.contains(layer)
        }
    }
}
