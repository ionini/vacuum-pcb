import Foundation

/// Unordered pair of pins, used to key per-wire routing waypoints. Stores its
/// two pins in a canonical order so (a, b) and (b, a) compare equal.
struct PinPair: Codable, Hashable {
    var a: PinRef
    var b: PinRef
    init(_ x: PinRef, _ y: PinRef) {
        if PinPair.key(x) <= PinPair.key(y) { a = x; b = y } else { a = y; b = x }
    }
    private static func key(_ p: PinRef) -> String { p.componentId.uuidString + "#" + p.pinKey }
}

/// User-placed routing waypoints for one wire (identified by its pin pair).
/// Purely a drawing hint — it bends the rendered wire through these points
/// without changing the net's connectivity or simulation. Points are in
/// schematic coordinates, ordered from `pair.a` toward `pair.b`.
struct WireWaypoints: Codable, Hashable {
    var pair: PinPair
    var points: [Point]
}

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
    /// Per-wire routing waypoints, keyed by pin pair. Optional (nil when none)
    /// so designs saved before waypoints existed decode unchanged and round-trip
    /// byte-for-byte.
    var wireWaypoints: [WireWaypoints]? = nil

    static let empty = SchematicLayout(positions: [])

    /// Schematic grid pitch (SwiftUI points). Component positions snap to this
    /// on drag so parts line up in rows/columns and their wires meet cleanly.
    static let gridStep: Double = 20

    /// Rounds a schematic point to the nearest grid intersection.
    static func snapToGrid(_ p: Point) -> Point {
        Point(x: (p.x / gridStep).rounded() * gridStep,
              y: (p.y / gridStep).rounded() * gridStep)
    }

    func position(for componentId: UUID) -> Point? {
        positions.first(where: { $0.componentId == componentId })?.position
    }

    /// Routing waypoints for the wire between two pins, oriented to match the
    /// queried `a → b` direction. Empty when the wire has none.
    func waypoints(_ a: PinRef, _ b: PinRef) -> [Point] {
        let pair = PinPair(a, b)
        guard let entry = wireWaypoints?.first(where: { $0.pair == pair }) else { return [] }
        return entry.pair.a == a ? entry.points : Array(entry.points.reversed())
    }

    /// Replaces the waypoints for a wire (points given in `a → b` order).
    /// Storing an empty list clears them and keeps the file byte-stable.
    mutating func setWaypoints(_ points: [Point], a: PinRef, b: PinRef) {
        let pair = PinPair(a, b)
        let oriented = pair.a == a ? points : Array(points.reversed())
        var list = wireWaypoints ?? []
        list.removeAll { $0.pair == pair }
        if !oriented.isEmpty { list.append(WireWaypoints(pair: pair, points: oriented)) }
        wireWaypoints = list.isEmpty ? nil : list
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

    /// Moves one waypoint of a wire to a new point.
    mutating func moveWaypoint(pair: PinPair, index: Int, to point: Point) {
        guard let li = wireWaypoints?.firstIndex(where: { $0.pair == pair }),
              wireWaypoints![li].points.indices.contains(index) else { return }
        wireWaypoints![li].points[index] = point
    }

    /// Removes one waypoint of a wire, rejoining the two segments. Drops the
    /// entry (and the whole list) when it empties, keeping the file byte-stable.
    mutating func removeWaypoint(pair: PinPair, index: Int) {
        guard let li = wireWaypoints?.firstIndex(where: { $0.pair == pair }),
              wireWaypoints![li].points.indices.contains(index) else { return }
        wireWaypoints![li].points.remove(at: index)
        if wireWaypoints![li].points.isEmpty { wireWaypoints!.remove(at: li) }
        if wireWaypoints?.isEmpty == true { wireWaypoints = nil }
    }

    mutating func remove(componentId: UUID) {
        positions.removeAll { $0.componentId == componentId }
        if var list = wireWaypoints {
            list.removeAll {
                $0.pair.a.componentId == componentId || $0.pair.b.componentId == componentId
            }
            wireWaypoints = list.isEmpty ? nil : list
        }
    }

    /// Drops waypoints whose pin pair is no longer a connected wire — a
    /// waypoint only has a wire to bend if both its pins still exist *and*
    /// share a net. Call after any edit that removes a net, component, or pin
    /// so stale waypoint handles don't linger on the canvas (and don't ride
    /// along into the saved file). Keeps the file byte-stable when nothing
    /// changes.
    mutating func pruneWaypoints(connectedIn nets: [Net]) {
        guard var list = wireWaypoints else { return }
        let before = list.count
        list.removeAll { wp in
            !nets.contains { $0.pins.contains(wp.pair.a) && $0.pins.contains(wp.pair.b) }
        }
        guard list.count != before else { return }
        wireWaypoints = list.isEmpty ? nil : list
    }
}
