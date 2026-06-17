import Foundation

/// Position of one component on the schematic canvas. Mirrors Placement's role on
/// the physical side, but coordinates here are SwiftUI points (not millimeters) and
/// have no manufacturing meaning — pure view layout.
struct SchematicPosition: Codable, Hashable {
    var componentId: UUID
    var position: Point
    /// Schematic-only orientation in 90° clockwise quarter-turns (0…3). Pure
    /// view layout — rotates which side the symbol's pins sit on; the physical
    /// CAD side is untouched. Optional (nil ≡ 0) so designs saved before
    /// rotation existed decode unchanged and round-trip byte-for-byte.
    var rotationQuarterTurns: Int? = nil
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

    /// Current orientation in normalized 90° clockwise quarter-turns (0…3).
    /// Defaults to 0 for components with no stored position or rotation.
    func rotation(for componentId: UUID) -> Int {
        let q = positions.first(where: { $0.componentId == componentId })?.rotationQuarterTurns ?? 0
        return ((q % 4) + 4) % 4
    }

    /// Rotates a component by `delta` quarter-turns (clockwise for positive),
    /// normalizing into 0…3. Stores nil when the result is 0 so an unrotated
    /// component keeps its file byte-stable. Creates an entry (at the canvas
    /// default spot) if the component has no stored position yet.
    mutating func rotate(componentId: UUID, by delta: Int) {
        if let i = positions.firstIndex(where: { $0.componentId == componentId }) {
            let next = (((positions[i].rotationQuarterTurns ?? 0) + delta) % 4 + 4) % 4
            positions[i].rotationQuarterTurns = next == 0 ? nil : next
        } else {
            let next = ((delta % 4) + 4) % 4
            positions.append(SchematicPosition(
                componentId: componentId,
                position: Point(x: 200, y: 200),
                rotationQuarterTurns: next == 0 ? nil : next
            ))
        }
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
