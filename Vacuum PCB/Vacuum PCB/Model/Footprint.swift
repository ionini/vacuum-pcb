import Foundation

/// Which plate a pin sits on, relative to the placement's primary layer.
/// - `.same`: same plate as the placement.
/// - `.opposite`: the other plate (used for transistor source/drain pins, which are
///   on the plate opposite the dimple).
enum RelativeLayer: Hashable {
    case same
    case opposite

    func resolved(against base: Plate) -> Plate {
        switch self {
        case .same: return base
        case .opposite: return base.opposite
        }
    }
}

/// One pin of a component footprint.
/// - `offset` is in millimeters relative to the component anchor at rotation r0.
/// - `relativeLayer` is the pin's plate relative to the placement's primary layer.
/// - `absoluteLayer` pins the pin to a specific `Layer` (plate + depth),
///   bypassing the relative-to-placement rule. Used by sub-part instance pins,
///   whose layer comes from the library file's internal port placement rather
///   than from the parent's `placement.layer` (which is metadata-only for
///   sub-parts since their internals each carry their own absolute layers).
struct FootprintPin: Hashable {
    let key: String
    let offset: Point
    let relativeLayer: RelativeLayer
    let absoluteLayer: Layer?

    init(key: String, offset: Point, relativeLayer: RelativeLayer, absoluteLayer: Layer? = nil) {
        self.key = key
        self.offset = offset
        self.relativeLayer = relativeLayer
        self.absoluteLayer = absoluteLayer
    }
}

/// Static geometric description of a component kind.
/// All values are in millimeters at rotation r0; rotation/translation applied at render time.
struct Footprint {
    let kind: ComponentKind
    let pins: [FootprintPin]

    /// Axis-aligned bounding box of the exclusion zone (no foreign channels may cross),
    /// at rotation r0. Origin is relative to the component anchor.
    let exclusionRect: Rect

    /// Loose visual bounding box for placement UI and snapping. At rotation r0.
    let boundingRect: Rect

    func pin(_ key: String) -> FootprintPin? {
        pins.first(where: { $0.key == key })
    }
}

extension ComponentKind {
    /// Resolves the footprint of this kind. Manufacturing constants drive
    /// transistor pin offsets and the gate dome's footprint extent.
    /// `resistorSize` is required only for `.resistor`.
    func footprint(resistorSize: ResistorSize? = nil,
                   manufacturing m: ManufacturingConstants = .defaults) -> Footprint {
        switch self {
        case .transistor:
            let halfPitch = m.padsOffset
            let dimpleRadius = m.dimpleDiameter / 2
            let margin = 0.5
            // Bounding/exclusion box must contain both the gate dome footprint
            // and the source/drain pin offsets, since either can be the
            // wider extent depending on configuration.
            let half = max(dimpleRadius + margin, halfPitch + margin)
            return Footprint(
                kind: .transistor,
                pins: [
                    FootprintPin(key: "gate", offset: .zero, relativeLayer: .same),
                    FootprintPin(key: "a", offset: Point(x: -halfPitch, y: 0), relativeLayer: .opposite),
                    FootprintPin(key: "b", offset: Point(x: halfPitch, y: 0), relativeLayer: .opposite),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )

        case .resistor:
            // Resistor footprint is the same physical size regardless of S/M/L.
            // The S/M/L choice picks how aggressively the serpentine zigzags
            // inside this bounding box, *not* how big the body is.
            let length = ManufacturingConstants.resistorFootprintLength
            let width = ManufacturingConstants.resistorFootprintWidth
            let halfLen = length / 2
            let halfWid = width / 2
            return Footprint(
                kind: .resistor,
                pins: [
                    FootprintPin(key: "1", offset: Point(x: -halfLen, y: 0), relativeLayer: .same),
                    FootprintPin(key: "2", offset: Point(x: halfLen, y: 0), relativeLayer: .same),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -halfLen, y: -halfWid),
                    size: Size(width: length, height: width)
                ),
                boundingRect: Rect(
                    origin: Point(x: -halfLen, y: -halfWid),
                    size: Size(width: length, height: width)
                )
            )

        case .vacuumSource, .atmVent, .port:
            // Edge-entry horizontal bore. Anchor sits at the inner (channel-side) end;
            // rotation chooses the outgoing edge (r0 = +X, r90 = +Y, r180 = -X, r270 = -Y).
            // Pin "p" lives on the placement's layer (which plate the bore is drilled into).
            let half = 1.5
            return Footprint(
                kind: self,
                pins: [
                    FootprintPin(key: "p", offset: .zero, relativeLayer: .same),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )

        case .subpart:
            // Subpart footprint is library-dependent; callers should go
            // through `Component.footprint(_:)` so the part filename is in
            // scope. This branch returns a minimal empty footprint for the
            // few utility paths (e.g. cycling kinds) that don't have a
            // component handy.
            return Footprint(
                kind: .subpart, pins: [],
                exclusionRect: Rect(origin: .zero, size: Size(width: 0, height: 0)),
                boundingRect: Rect(origin: .zero, size: Size(width: 0, height: 0))
            )

        case .led:
            // Single fluid pin at the centre (the dimple's gate equivalent).
            // Footprint extent has to clear the viewing hole on the opposite
            // plate too, which is 1 mm wider in diameter than the dimple.
            let dimpleRadius = m.ledDimpleDiameter / 2
            let viewRadius = dimpleRadius + 0.5
            let margin = 0.5
            let half = viewRadius + margin
            return Footprint(
                kind: .led,
                pins: [
                    FootprintPin(key: "p", offset: .zero, relativeLayer: .same),
                ],
                exclusionRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )

        case .screw:
            // Screws are mechanical-only: no fluid pins. Exclusion = head
            // countersink radius so the auto-router avoids running channels
            // under the head cavity. Bounding rect adds a hair of slack so
            // the parking-lot / canvas hit target stays grabbable.
            let headRadius = ScrewGeometry.headDiameter / 2
            let half = headRadius + 0.2
            return Footprint(
                kind: .screw, pins: [],
                exclusionRect: Rect(
                    origin: Point(x: -headRadius, y: -headRadius),
                    size: Size(width: 2 * headRadius, height: 2 * headRadius)
                ),
                boundingRect: Rect(
                    origin: Point(x: -half, y: -half),
                    size: Size(width: 2 * half, height: 2 * half)
                )
            )

        case .connector:
            // Use the no-pinCount fallback (1 pin, .bottomExtend). Callers
            // that have a Component handy must go through the
            // `Component.footprint(_:)` overload so pin count and role drive
            // the slot count.
            return Self.connectorFootprint(pinCount: 1, role: .bottomExtend, manufacturing: m)
        }
    }

    /// Connector footprint generator. Anchor sits at the centre of the slot
    /// row, on the plate edge — i.e., the point where the protrusion's inner
    /// face meets the boardOutline. At rotation r0 the protrusion extends
    /// along +X (east edge); the four edges are 90° rotations of that.
    ///
    /// Slot layout along the row at r0 (read along +Y, the connector's
    /// tangent axis): `[end-screw] [pin 1] … [pin N] [end-screw]`. Pin keys
    /// are decimal strings "1"…"N". End-cap screws are mechanical-only and
    /// don't appear in `pins` (they're drawn / cut by `PlateBuilder` from
    /// the same anchor + role).
    ///
    /// Pin plate follows the role: `.bottomExtend` puts pins on the bottom
    /// plate (silicone-facing surface), `.topExtend` on the top plate. The
    /// `Placement.layer` for a connector is set to match the role so the
    /// existing `relativeLayer: .same` rule lands every pin on the right
    /// plate without further special-casing.
    /// Centre-to-centre spacing between adjacent connector pin tubes.
    /// Hardcoded — driven by the connector's mechanical layout, not by
    /// the document's grid pitch. Promote to `ManufacturingConstants` if
    /// designs ever need to vary per-doc.
    static let connectorTubePitch: Double = 5.0

    /// Centre-to-centre distance between an end-cap screw and the nearest
    /// pin tube. Larger than `connectorTubePitch` so the screw head face
    /// (5.1 mm) has comfortable clearance against the adjacent tube. Same
    /// "hardcoded for now" caveat as `connectorTubePitch`.
    static let connectorEndCapOffset: Double = 8.0

    /// Centre-to-centre spacing between a debug-mode connector's tube
    /// sockets. Wider than `connectorTubePitch` so push-in tubes (and the
    /// fingers seating them) fit side by side on the board edge.
    static let connectorDebugPortPitch: Double = 10.0

    /// How far inside the anchor edge a debug-mode pin (the route end of
    /// its bore) sits. This is the bore length, and with the taper it sets
    /// the mouth width at the edge face — 10 mm at the default 1° taper
    /// opens the 1.7 mm bore to ≈2.05 mm, the same socket a hand-placed
    /// port 10 mm from the edge gets.
    static let connectorDebugPortInset: Double = 10.0

    /// Layer a debug-mode socket sits on when the user hasn't moved it:
    /// the role's plate at the silicone-facing depth — the same plate the
    /// real connector's pins would land on, so toggling debug leaves
    /// routing plans intact by default.
    static func connectorDebugPortDefaultLayer(role: ConnectorRole) -> Layer {
        Layer(plate: role == .bottomExtend ? .bottom : .top, depth: 0)
    }

    /// Lowest legal screw count: two end caps always clamp the joint, which
    /// is also the legacy (pre-screw-count) layout.
    static let connectorMinScrewCount = 2

    /// Highest screw count that still leaves at least one pin in every
    /// inter-screw group (`screwCount - 1` groups, each ≥ 1 pin).
    static func connectorMaxScrewCount(pinCount: Int) -> Int {
        max(connectorMinScrewCount, max(1, pinCount) + 1)
    }

    /// Pin and screw centres along a connector's tangent axis (local Y), both
    /// sorted ascending and symmetric about the anchor at 0.
    struct ConnectorRow {
        /// One entry per pin, in slot order (index 0 = smallest Y).
        var pinYs: [Double]
        /// One entry per clamp screw.
        var screwYs: [Double]
    }

    /// Single source of truth for a connector's 1-D layout, shared by the
    /// footprint, the CAD cutters, the 2-D symbols, and the outline geometry
    /// so every surface agrees on where pins and screws land.
    ///
    /// `screwCount == 2` puts both screws `connectorEndCapOffset` past the
    /// outermost pins — the exact legacy geometry. Three or more splits the
    /// pins into `screwCount - 1` contiguous groups, as even as possible with
    /// any remainder going to the trailing groups (7 pins, 3 screws → 3 | 4),
    /// and drops one extra screw between each pair of groups. Every screw —
    /// end cap or interior — keeps `connectorEndCapOffset` clearance to its
    /// neighbouring pins, so an interior screw gets the same head room the end
    /// caps were tuned for; the trade-off is a longer connector. `screwCount`
    /// is clamped to keep every group non-empty.
    static func connectorRow(pinCount: Int, screwCount: Int) -> ConnectorRow {
        let n = max(1, pinCount)
        let s = min(max(connectorMinScrewCount, screwCount),
                    connectorMaxScrewCount(pinCount: n))
        let groupCount = s - 1                       // pin groups between screws
        let base = n / groupCount
        let remainder = n % groupCount
        // Leading groups get `base` pins; the trailing `remainder` groups get
        // one more, so the larger half lands last (matches 7 pins → 3 | 4).
        let groupSizes = (0..<groupCount).map { $0 < groupCount - remainder ? base : base + 1 }

        var pinYs: [Double] = []
        var screwYs: [Double] = []
        var cursor = 0.0
        screwYs.append(cursor)                       // first end cap
        for size in groupSizes {
            cursor += connectorEndCapOffset          // clearance before the group
            for k in 0..<size {
                if k > 0 { cursor += connectorTubePitch }
                pinYs.append(cursor)
            }
            cursor += connectorEndCapOffset          // clearance after the group
            screwYs.append(cursor)                   // screw closing this group
        }
        // Centre the row on the anchor (local origin).
        let centre = cursor / 2
        return ConnectorRow(
            pinYs: pinYs.map { $0 - centre },
            screwYs: screwYs.map { $0 - centre }
        )
    }

    /// Local-Y centres of a connector's clamp screws, ascending. Used by
    /// `PlateBuilder` (cutters), `PlacementBodyView` (symbol), and the
    /// stencil / outline geometry. See `connectorRow`.
    static func connectorScrewLocalYs(pinCount: Int, screwCount: Int) -> [Double] {
        connectorRow(pinCount: pinCount, screwCount: screwCount).screwYs
    }

    /// Outward extent (perpendicular to the row) of the connector
    /// protrusion. Sized so the screw head face fits inside the
    /// protrusion's perpendicular footprint with `minWallThickness` of
    /// plate material on each side. Snapped up to `gridPitch` for the
    /// same grid-alignment reason as the pin layout.
    static func connectorOutwardExtent(manufacturing m: ManufacturingConstants) -> Double {
        let headFit = ScrewGeometry.headDiameter + 2 * m.minWallThickness
        let grid = max(m.gridPitch, 0.0001)
        let steps = (headFit / grid).rounded(.up)
        return max(grid, steps * grid)
    }

    static func connectorFootprint(
        pinCount: Int,
        screwCount: Int = connectorMinScrewCount,
        role: ConnectorRole,
        debugPorts: Bool = false,
        debugPortLayers: [Layer]? = nil,
        manufacturing m: ManufacturingConstants
    ) -> Footprint {
        let n = max(1, pinCount)
        if debugPorts {
            return connectorDebugPortsFootprint(pinCount: n, role: role, layers: debugPortLayers)
        }
        let row = connectorRow(pinCount: n, screwCount: screwCount)
        let endCapY = row.screwYs.last ?? 0      // outermost screw |y| (symmetric)
        // Row extends `headRadius + minWallThickness` past each end-cap so
        // the screw head face has plate material around it. That sets the
        // exclusion / bounding rect's tangent extent.
        let headRadius = ScrewGeometry.headDiameter / 2
        let halfRow = endCapY + headRadius + m.minWallThickness
        let rowLength = 2 * halfRow
        // Protrusion sticks out along local +X (away from the plate
        // interior). The extent is sized so the screw head face fits
        // inside the protrusion footprint with at least `minWallThickness`
        // of plate material on each side — see `connectorOutwardExtent`.
        let outwardExtent = connectorOutwardExtent(manufacturing: m)
        var pins: [FootprintPin] = []
        // Pin 1 sits next to one end screw, pin N next to the other. The
        // pins are centred on the row anchor with `connectorTubePitch`
        // spacing; the end-caps sit `connectorEndCapOffset` past the
        // outermost pins on either side.
        //
        // Role flips the slot direction: `.topExtend` lays pin 1 at the
        // smallest local y (mating side viewed top-down); `.bottomExtend`
        // lays pin 1 at the largest local y so the order matches the
        // schematic symbol after the user's natural mental view-flip
        // (looking at the bottom-plate protrusion from the silicone side).
        // Net effect for two mating halves on separate `.vpcb` files: a
        // designer who places pin "1" → matching net on both halves will
        // see them line up at the same end of the slot row in physical.
        for i in 0..<n {
            let pinIndex = i + 1
            let step: Int
            switch role {
            case .topExtend:    step = i               // pin 1 at smallest y
            case .bottomExtend: step = (n - 1) - i     // pin 1 at largest y
            }
            let y = row.pinYs[step]
            pins.append(FootprintPin(
                key: "\(pinIndex)",
                offset: Point(x: outwardExtent / 2, y: y),
                relativeLayer: .same
            ))
        }
        // Bounding / exclusion rect covers the full protrusion area (0 ≤ x
        // ≤ outwardExtent along local +X, -halfRow ≤ y ≤ halfRow). The
        // anchor sits at the inner edge (x=0), so the rect's origin.x is 0.
        let rect = Rect(
            origin: Point(x: 0, y: -halfRow),
            size: Size(width: outwardExtent, height: rowLength)
        )
        return Footprint(
            kind: .connector,
            pins: pins,
            exclusionRect: rect,
            boundingRect: rect
        )
    }

    /// Debug-print connector footprint: no protrusion, no screws — just a
    /// row of edge port bores drilled from inside the board out through the
    /// anchor edge. Pins sit `connectorDebugPortInset` inside the edge
    /// (local -X; the anchor stays on the edge with +X outward) on a
    /// centred `connectorDebugPortPitch` grid, and keep the same role-based
    /// pin-1 end as the normal footprint so toggling debug never flips the
    /// row. Each pin owns one pitch-wide slot, so the rect — which drives
    /// edge snapping, corner clearance, and exclusion DRC — spans exactly
    /// `n × pitch` along the edge and covers the bore path inward.
    ///
    /// `layers` is the per-socket layer choice (`connectorDebugPortLayers`,
    /// positional by pin number); missing entries fall back to the role's
    /// plate at depth 0. Each pin carries its layer in `absoluteLayer`, so
    /// pin handles, routing, ratsnest, DRC, and the CAD all resolve the
    /// per-socket choice without knowing about the connector.
    static func connectorDebugPortsFootprint(
        pinCount: Int, role: ConnectorRole, layers: [Layer]? = nil
    ) -> Footprint {
        let n = max(1, pinCount)
        let pitch = connectorDebugPortPitch
        let inset = connectorDebugPortInset
        let fallback = connectorDebugPortDefaultLayer(role: role)
        var pins: [FootprintPin] = []
        for i in 0..<n {
            let pinIndex = i + 1
            let step: Int
            switch role {
            case .topExtend:    step = i               // pin 1 at smallest y
            case .bottomExtend: step = (n - 1) - i     // pin 1 at largest y
            }
            let y = (Double(step) - Double(n - 1) / 2) * pitch
            let layer = (layers?.indices.contains(i) ?? false) ? layers![i] : fallback
            pins.append(FootprintPin(
                key: "\(pinIndex)",
                offset: Point(x: -inset, y: y),
                relativeLayer: .same,
                absoluteLayer: layer
            ))
        }
        let halfRow = Double(n) * pitch / 2
        let rect = Rect(
            origin: Point(x: -inset, y: -halfRow),
            size: Size(width: inset, height: 2 * halfRow)
        )
        return Footprint(
            kind: .connector,
            pins: pins,
            exclusionRect: rect,
            boundingRect: rect
        )
    }

    /// Same signature as the original `footprint`, plus a named parameter so
    /// call sites that have a `ManufacturingConstants` value can still resolve
    /// the gate-dome / pad geometry. Subpart resolution still requires a
    /// `Component` (filename lives there), so it goes through the
    /// component-level overload below.
    func footprint(manufacturing m: ManufacturingConstants) -> Footprint {
        footprint(resistorSize: nil, manufacturing: m)
    }

    /// Convenience: list of legal pin keys for this component kind. Subparts
    /// have library-derived pins — go through `Component.pinKeys` instead.
    /// Connectors carry a variable pin count — go through `Component.pinKeys`
    /// so the instance's `connectorPinCount` is in scope.
    var pinKeys: [String] {
        switch self {
        case .transistor:   return ["gate", "a", "b"]
        case .resistor:     return ["1", "2"]
        case .vacuumSource, .atmVent, .port: return ["p"]
        case .subpart:      return []
        case .screw:        return []
        case .led:          return ["p"]
        case .connector:    return []
        }
    }
}

extension Component {
    /// Resolves the footprint for this component using the document's
    /// manufacturing constants. Transistor pin offsets and the gate dome's
    /// bounding box track the manufacturing config; resistor and port
    /// footprints don't depend on it. Subparts resolve via
    /// `Component.resolvedPart(snapshots:)` — pass the parent doc's
    /// `librarySnapshots` so a v3 pinned instance uses its frozen library
    /// copy rather than whatever's on disk now. Defaulting to `[:]` falls
    /// through to the live library (correct for unpinned / missing-hash
    /// cases, plus call sites that haven't been threaded yet).
    func footprint(_ m: ManufacturingConstants, snapshots: [String: CircuitDocument] = [:]) -> Footprint {
        if kind == .subpart {
            return subpartFootprint(snapshots: snapshots) ?? kind.footprint(resistorSize: resistorSize, manufacturing: m)
        }
        if kind == .connector {
            return ComponentKind.connectorFootprint(
                pinCount: connectorPinCount ?? 1,
                screwCount: connectorScrewCount ?? ComponentKind.connectorMinScrewCount,
                role: connectorRole ?? .bottomExtend,
                debugPorts: connectorDebugPorts ?? false,
                debugPortLayers: connectorDebugPortLayers,
                manufacturing: m
            )
        }
        return kind.footprint(resistorSize: resistorSize, manufacturing: m)
    }

    /// Default-constants fallback for call sites that don't have a circuit
    /// document handy. Don't use in code that has to match the actual CAD
    /// geometry — it'll be wrong as soon as the user changes the manufacturing.
    var footprint: Footprint {
        if kind == .subpart {
            return subpartFootprint(snapshots: [:]) ?? kind.footprint(resistorSize: resistorSize)
        }
        if kind == .connector {
            return ComponentKind.connectorFootprint(
                pinCount: connectorPinCount ?? 1,
                screwCount: connectorScrewCount ?? ComponentKind.connectorMinScrewCount,
                role: connectorRole ?? .bottomExtend,
                debugPorts: connectorDebugPorts ?? false,
                debugPortLayers: connectorDebugPortLayers,
                manufacturing: .defaults
            )
        }
        return kind.footprint(resistorSize: resistorSize)
    }

    /// Subpart pin keys = the library file's boundary pin UUID strings, in
    /// the order PartsLibrary returns them. Connector pin keys are "1"…"N"
    /// driven by the instance's pin count. Other primitive kinds fall back
    /// to `ComponentKind.pinKeys`.
    func pinKeys(snapshots: [String: CircuitDocument] = [:]) -> [String] {
        if kind == .subpart, let part = resolvedPart(snapshots: snapshots) {
            return part.pins.map { $0.portId.uuidString }
        }
        if kind == .connector {
            let n = max(1, connectorPinCount ?? 1)
            return (1...n).map { String($0) }
        }
        return kind.pinKeys
    }

    /// Looks up the `BoundaryPin` matching one of this sub-part's pin keys.
    /// Useful for callers that need the pin's library plate (visibility
    /// filtering) or its friendly label without going through the footprint
    /// system. Returns nil for primitives and missing parts.
    func subpartBoundaryPin(key: String, snapshots: [String: CircuitDocument] = [:]) -> BoundaryPin? {
        guard let part = resolvedPart(snapshots: snapshots) else { return nil }
        return part.pins.first(where: { $0.portId.uuidString == key })
    }

    /// Builds a Footprint for a `.subpart` instance from its library file.
    /// Anchor sits at the library's `boardOutline.origin` (top-left corner)
    /// — meaning the parent-side `Placement.position` represents where that
    /// corner lands on the parent board. Anchoring at the corner (rather
    /// than the centre) keeps pin offsets equal to the child file's port
    /// coordinates, so a grid-snapped parent placement gives grid-aligned
    /// pin positions for any child whose ports sit on the grid — even
    /// children with odd outline width/height.
    ///
    /// Returns nil when the library file isn't loaded (missing-part case).
    /// Callers should treat that as "render placeholder".
    func subpartFootprint(snapshots: [String: CircuitDocument] = [:]) -> Footprint? {
        guard let part = resolvedPart(snapshots: snapshots) else { return nil }
        let outline = part.document.physical.boardOutline
        let ox = outline.minX
        let oy = outline.minY
        let pins = part.pins.map { p in
            FootprintPin(
                key: p.portId.uuidString,
                offset: Point(x: p.physicalAnchor.x - ox, y: p.physicalAnchor.y - oy),
                relativeLayer: .same,
                absoluteLayer: Layer(plate: p.plate, depth: p.depth)
            )
        }
        let rect = Rect(origin: .zero, size: outline.size)
        return Footprint(kind: .subpart, pins: pins, exclusionRect: rect, boundingRect: rect)
    }
}

extension FootprintPin {
    /// Offset rotated by `rotation`; translation to world is left to the caller.
    func rotatedOffset(_ rotation: Rotation) -> Point {
        let r = rotation.radians
        let c = cos(r)
        let s = sin(r)
        return Point(x: offset.x * c - offset.y * s,
                     y: offset.x * s + offset.y * c)
    }
}

extension Placement {
    /// World-coordinate position of a pin on this placement.
    func worldPosition(of pin: FootprintPin) -> Point {
        let rotated = pin.rotatedOffset(rotation)
        return Point(x: position.x + rotated.x, y: position.y + rotated.y)
    }

    /// Resolved plate the pin actually sits on. Component pins are anchored
    /// to a plate (not a depth) — they always live at the silicone-facing
    /// surface (depth 0). Pins that carry an `absoluteLayer` (today: sub-part
    /// boundary pins) bypass the placement-relative rule and use that layer's
    /// plate directly.
    func resolvedPlate(of pin: FootprintPin) -> Plate {
        if let absolute = pin.absoluteLayer { return absolute.plate }
        return pin.relativeLayer.resolved(against: layer)
    }

    /// Resolved full `Layer` for a pin. Transistors are pinned to depth 0
    /// (their dimple/dome geometry only makes sense at the silicone-facing
    /// layer). Resistors are tubes and ports/vents/vacuum sources are edge
    /// bores — both are just holes drilled into the plate, so they can sit
    /// on any channel layer and their pins inherit `placement.depth`.
    /// Sub-part boundary pins carry the library's internal port layer in
    /// `absoluteLayer`, so a route started from the pin lands on whichever
    /// plate + depth that port was on inside the library file.
    func resolvedLayer(of pin: FootprintPin, on component: Component) -> Layer {
        if let absolute = pin.absoluteLayer { return absolute }
        let plate = resolvedPlate(of: pin)
        let useDepth: Int
        switch component.kind {
        case .resistor, .port, .vacuumSource, .atmVent:
            useDepth = depth
        case .transistor, .subpart, .screw, .led, .connector:
            useDepth = 0
        }
        return Layer(plate: plate, depth: useDepth)
    }
}
