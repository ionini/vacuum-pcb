import Foundation

/// What's selected on the physical canvas.
enum PhysicalSelection: Hashable {
    case none
    case placement(componentId: UUID)
    case routeSegment(netId: UUID, segmentIndex: Int)

    var placementComponentId: UUID? {
        if case let .placement(id) = self { return id }
        return nil
    }

    /// True when ⌫ has something to remove. Used to gate the hidden
    /// keyboardShortcut(.delete) button — see SchematicSelection for the
    /// rationale.
    var isDeletable: Bool {
        switch self {
        case .placement, .routeSegment: return true
        case .none:                     return false
        }
    }
}

/// State of the click-pin → click-waypoints → click-pin routing interaction.
/// `waypoints` is the in-progress polyline (world mm). The pinning starts on
/// the first pin, so `waypoints[0]` is the first pin's world location.
enum RoutingState: Hashable {
    case idle
    case routing(netId: UUID, waypoints: [Point], layer: Layer)

    var inProgress: Bool {
        if case .routing = self { return true }
        return false
    }
}

/// Which layers are visible in the physical editor.
struct LayerVisibility: Hashable {
    var top: Bool
    var bottom: Bool

    static let both   = LayerVisibility(top: true,  bottom: true)
    static let topOnly    = LayerVisibility(top: true,  bottom: false)
    static let bottomOnly = LayerVisibility(top: false, bottom: true)

    func contains(_ layer: Layer) -> Bool {
        switch layer {
        case .top: return top
        case .bottom: return bottom
        }
    }
}
