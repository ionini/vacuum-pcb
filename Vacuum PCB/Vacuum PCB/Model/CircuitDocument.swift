import Foundation

struct CircuitDocument: Codable, Hashable {
    /// Bumped to 2 when sub-part placements switched from centre-anchor to
    /// corner-anchor (Placement.position now stores the library outline's
    /// top-left corner in parent-world rather than the centre). Old files
    /// are migrated transparently in `decoded(from:)`.
    static let currentSchemaVersion = 2

    var schemaVersion: Int
    var manufacturing: ManufacturingConstants
    var logic: LogicGraph
    var schematic: SchematicLayout
    var physical: PhysicalLayout

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manufacturing: ManufacturingConstants = .defaults,
        logic: LogicGraph,
        schematic: SchematicLayout = .empty,
        physical: PhysicalLayout
    ) {
        self.schemaVersion = schemaVersion
        self.manufacturing = manufacturing
        self.logic = logic
        self.schematic = schematic
        self.physical = physical
    }
}

extension CircuitDocument {
    /// Produces a primitives-only copy of the document with every `.subpart`
    /// instance expanded into its library file's internal placements and
    /// routes. Internals get fresh UUIDs (so two XOR instances don't
    /// collide), transformed by the instance pose. Boundary components
    /// (port / vacuumSource / atmVent inside the library file) are dropped:
    /// they're connection markers in the parent view, not real bores.
    ///
    /// This is what the CAD pipeline (PlateBuilder, SimulatorExporter)
    /// operates on. DRC and Ratsnest run against the unflattened doc and
    /// treat subparts as black-box obstacles per the v1 design — flattening
    /// for them would also be valid, just more expensive on every keystroke.
    ///
    /// Subparts whose library file is missing are silently dropped (already
    /// surfaced as a red placeholder in the canvas).
    func flattened() -> CircuitDocument {
        var primitives = self
        var components = primitives.logic.components.filter { $0.kind != .subpart }
        var placements: [Placement] = primitives.physical.placements.filter { p in
            self.logic.components.first(where: { $0.id == p.componentId })?.kind != .subpart
        }
        var routes = primitives.physical.routes

        for placement in self.physical.placements {
            guard let comp = self.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let part = comp.partRef.flatMap({ PartsLibrary.shared.part(named: $0) })
            else { continue }

            let outline = part.document.physical.boardOutline
            let ox = outline.minX
            let oy = outline.minY
            let r = placement.rotation.radians
            let cosR = cos(r), sinR = sin(r)

            func toWorld(_ p: Point) -> Point {
                let dx = p.x - ox, dy = p.y - oy
                return Point(
                    x: placement.position.x + dx * cosR - dy * sinR,
                    y: placement.position.y + dx * sinR + dy * cosR
                )
            }

            // Internal placements (skip boundary components — they're pin
            // markers in the parent view, not real fluid features).
            for internalPlacement in part.document.physical.placements {
                guard let internalComp = part.document.logic.components
                        .first(where: { $0.id == internalPlacement.componentId }),
                      internalComp.kind != .port,
                      internalComp.kind != .vacuumSource,
                      internalComp.kind != .atmVent,
                      internalComp.kind != .subpart  // defensive: library is flat-only but guard anyway
                else { continue }

                let newId = UUID()
                placements.append(Placement(
                    componentId: newId,
                    position: toWorld(internalPlacement.position),
                    rotation: Self.composeRotation(internalPlacement.rotation, then: placement.rotation),
                    layer: internalPlacement.layer,
                    depth: internalPlacement.depth
                ))
                components.append(Component(
                    id: newId,
                    kind: internalComp.kind,
                    label: "\(comp.label).\(internalComp.label)",
                    resistorSize: internalComp.resistorSize,
                    portDirection: internalComp.portDirection
                ))
            }

            // Internal routes. NetId is regenerated — PlateBuilder ignores
            // it, and reusing the library's netId could collide with a
            // parent net's id and confuse downstream code that does care.
            for route in part.document.physical.routes {
                let newSegments = route.segments.map { seg -> Segment in
                    let newWaypoints = seg.waypoints.map {
                        Waypoint(position: toWorld($0.position), kind: $0.kind)
                    }
                    return Segment(waypoints: newWaypoints, layer: seg.layer)
                }
                routes.append(Route(netId: UUID(), segments: newSegments))
            }
        }

        primitives.logic.components = components
        primitives.physical.placements = placements
        primitives.physical.routes = routes
        return primitives
    }

    private static func composeRotation(_ first: Rotation, then second: Rotation) -> Rotation {
        let order: [Rotation] = [.r0, .r90, .r180, .r270]
        let i = (order.firstIndex(of: first) ?? 0)
              + (order.firstIndex(of: second) ?? 0)
        return order[i % 4]
    }
}

extension CircuitDocument {
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let jsonDecoder = JSONDecoder()

    func encoded() throws -> Data {
        try Self.jsonEncoder.encode(self)
    }

    static func decoded(from data: Data) throws -> CircuitDocument {
        var doc = try jsonDecoder.decode(CircuitDocument.self, from: data)
        migrateInPlace(&doc)
        return doc
    }

    /// Forward-migrates a freshly decoded document. Keeps pin world positions
    /// (and therefore every route endpoint) invariant — geometry on screen
    /// after load is identical to what was written.
    private static func migrateInPlace(_ doc: inout CircuitDocument) {
        if doc.schemaVersion < 2 {
            migrateSubpartAnchorsCenterToCorner(&doc)
        }
        doc.schemaVersion = currentSchemaVersion
    }

    /// v1 → v2: sub-part `Placement.position` previously stored the library
    /// outline's centre in parent-world; v2 stores its top-left corner. Shift
    /// each subpart placement by the rotated half-extent so world geometry
    /// stays put. Children whose library file isn't loaded yet are left alone
    /// — the same flag will trigger again next launch once the library is
    /// available (worst case: a permanently-missing part is treated as v2,
    /// which is harmless because the placeholder doesn't reference pins).
    private static func migrateSubpartAnchorsCenterToCorner(_ doc: inout CircuitDocument) {
        for i in doc.physical.placements.indices {
            let placement = doc.physical.placements[i]
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let part = comp.partRef.flatMap({ PartsLibrary.shared.part(named: $0) })
            else { continue }
            let outline = part.document.physical.boardOutline
            let dx = outline.size.width / 2
            let dy = outline.size.height / 2
            let r = placement.rotation.radians
            let cosR = cos(r), sinR = sin(r)
            let shiftX = dx * cosR - dy * sinR
            let shiftY = dx * sinR + dy * cosR
            doc.physical.placements[i].position = Point(
                x: placement.position.x - shiftX,
                y: placement.position.y - shiftY
            )
        }
    }
}
