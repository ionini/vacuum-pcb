import Foundation

/// Position of one component on the schematic canvas. Mirrors Placement's role on
/// the physical side, but coordinates here are SwiftUI points (not millimeters) and
/// have no manufacturing meaning — pure view layout.
struct SchematicPosition: Codable, Hashable {
    var componentId: UUID
    var position: Point
}

/// View-layout data for the schematic editor. Owned by the schematic tab; physical
/// CAD ignores it entirely. A component without a position is rendered at a
/// default location on first display and acquires a stored position when the user
/// next moves it.
struct SchematicLayout: Codable, Hashable {
    var positions: [SchematicPosition]

    static let empty = SchematicLayout(positions: [])

    func position(for componentId: UUID) -> Point? {
        positions.first(where: { $0.componentId == componentId })?.position
    }

    mutating func setPosition(_ position: Point, for componentId: UUID) {
        if let i = positions.firstIndex(where: { $0.componentId == componentId }) {
            positions[i].position = position
        } else {
            positions.append(SchematicPosition(componentId: componentId, position: position))
        }
    }

    mutating func remove(componentId: UUID) {
        positions.removeAll { $0.componentId == componentId }
    }
}
