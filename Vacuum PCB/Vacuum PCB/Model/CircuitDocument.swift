import Foundation
import CryptoKit

struct CircuitDocument: Codable, Hashable {
    /// v2: sub-part placements switched from centre-anchor to corner-anchor.
    /// v3: every sub-part instance pins a content hash of the library doc at
    /// placement / last-update time, and the parent document carries a
    /// snapshot dictionary keyed by that hash. Subpart resolution reads the
    /// snapshot, never the live library, so library edits don't cascade into
    /// saved designs. Migrations run transparently in `decoded(from:)`.
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var manufacturing: ManufacturingConstants
    var logic: LogicGraph
    var schematic: SchematicLayout
    var physical: PhysicalLayout
    /// Frozen copies of every library document referenced by a sub-part in
    /// this design, keyed by content hash. Same key that lives on
    /// `Component.partRefHash`. Self-contained: opening a `.vpcb` doesn't
    /// require the user's parts folder. GC'd on save (entries whose hash isn't
    /// referenced get dropped).
    var librarySnapshots: [String: CircuitDocument]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manufacturing: ManufacturingConstants = .defaults,
        logic: LogicGraph,
        schematic: SchematicLayout = .empty,
        physical: PhysicalLayout,
        librarySnapshots: [String: CircuitDocument] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.manufacturing = manufacturing
        self.logic = logic
        self.schematic = schematic
        self.physical = physical
        self.librarySnapshots = librarySnapshots
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, manufacturing, logic, schematic, physical, librarySnapshots
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.manufacturing = try c.decode(ManufacturingConstants.self, forKey: .manufacturing)
        self.logic = try c.decode(LogicGraph.self, forKey: .logic)
        self.schematic = try c.decode(SchematicLayout.self, forKey: .schematic)
        self.physical = try c.decode(PhysicalLayout.self, forKey: .physical)
        // v2 and earlier files don't carry snapshots — migration populates
        // them from the live library after decode.
        self.librarySnapshots = try c.decodeIfPresent([String: CircuitDocument].self, forKey: .librarySnapshots) ?? [:]
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
    /// Library files may themselves contain subparts — those expand
    /// recursively (the child is pre-flattened, then its now-primitive
    /// placements are translated into the parent's frame). Reference cycles
    /// between files are detected via the `visiting` set and broken silently
    /// at the offending placement (which is dropped from the flattened
    /// output; the canvas surfaces the cycle as a red placeholder).
    ///
    /// This is what the CAD pipeline (PlateBuilder, SimulatorExporter)
    /// operates on. DRC and Ratsnest run against the unflattened doc and
    /// treat subparts as black-box obstacles per the v1 design — flattening
    /// for them would also be valid, just more expensive on every keystroke.
    ///
    /// Subparts whose library file is missing are silently dropped (already
    /// surfaced as a red placeholder in the canvas).
    func flattened() -> CircuitDocument {
        flattened(visiting: [])
    }

    /// Recursive worker for `flattened()`. `visiting` holds the chain of
    /// library filenames currently being expanded; a subpart whose `partRef`
    /// is already in that set is skipped (cycle).
    func flattened(visiting: Set<String>) -> CircuitDocument {
        var primitives = self
        var components = primitives.logic.components.filter { $0.kind != .subpart }
        var placements: [Placement] = primitives.physical.placements.filter { p in
            self.logic.components.first(where: { $0.id == p.componentId })?.kind != .subpart
        }
        var routes = primitives.physical.routes

        for placement in self.physical.placements {
            guard let comp = self.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let filename = comp.partRef,
                  !visiting.contains(filename),
                  let part = comp.resolvedPart(snapshots: self.librarySnapshots)
            else { continue }

            // Pre-flatten the child so any subparts inside it are already
            // expanded to primitives in the child's coordinate system. The
            // parent then only needs a single rotation/translation step.
            let childFlat = part.document.flattened(visiting: visiting.union([filename]))

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
            for internalPlacement in childFlat.physical.placements {
                guard let internalComp = childFlat.logic.components
                        .first(where: { $0.id == internalPlacement.componentId }),
                      internalComp.kind != .port,
                      internalComp.kind != .vacuumSource,
                      internalComp.kind != .atmVent
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
            for route in childFlat.physical.routes {
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

// Manual Hashable / Equatable: `librarySnapshots` recurses on `CircuitDocument`,
// which blocks synthesis. We treat the snapshot dict as bookkeeping — two docs
// with identical substantive content but different snapshot caches are equal
// for diffing / SwiftUI purposes. (`contentHash()` makes the same choice.)
extension CircuitDocument {
    func hash(into hasher: inout Hasher) {
        hasher.combine(schemaVersion)
        hasher.combine(manufacturing)
        hasher.combine(logic)
        hasher.combine(schematic)
        hasher.combine(physical)
    }

    static func == (lhs: CircuitDocument, rhs: CircuitDocument) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.manufacturing == rhs.manufacturing
            && lhs.logic == rhs.logic
            && lhs.schematic == rhs.schematic
            && lhs.physical == rhs.physical
    }
}

extension CircuitDocument {
    static let jsonEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    static let jsonDecoder = JSONDecoder()

    /// Stable content hash (hex SHA-256) of the substantive document state.
    /// Excludes:
    ///  - `librarySnapshots` (recursive bookkeeping, not identity)
    ///  - `schemaVersion` (re-saving at a newer version is still the same part)
    ///  - `Component.partRefHash` (a *cached* pointer to a snapshot, not part
    ///    of the doc's identity — pinning a deeper version of a transitive
    ///    dependency doesn't change WHAT this doc is, just where its
    ///    dependencies are cached. Stripping lets the migration fill in
    ///    missing inner pins without invalidating the parent's pin)
    /// Used as the snapshot-dict key. For staleness comparison — does this
    /// doc behave differently than another doc, including via transitive
    /// dependency changes — use `effectiveHash()` instead.
    func contentHash() -> String {
        var stripped = self
        stripped.librarySnapshots = [:]
        stripped.schemaVersion = 0
        for i in stripped.logic.components.indices {
            stripped.logic.components[i].partRefHash = nil
        }
        let data = (try? Self.jsonEncoder.encode(stripped)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Deep behavioural hash: covers everything that affects what this doc
    /// resolves to at flatten/CAD time, including which version of each
    /// nested library is pinned (`partRefHash`) and the actual content of
    /// every snapshot in `librarySnapshots` (which gets serialised
    /// recursively). Used for "Library has changes" staleness checks —
    /// transitive edits (e.g., XOR was edited two levels down) bump this
    /// hash even when the direct part's structural `contentHash()` is
    /// unchanged.
    func effectiveHash() -> String {
        var stripped = self
        stripped.schemaVersion = 0
        let data = (try? Self.jsonEncoder.encode(stripped)) ?? Data()
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Force-refresh every sub-part pin in this doc to point at the live
    /// library's current snapshot, regardless of whether the hash already
    /// matched. Used by `PartsLibrary.reload`'s second pass to propagate
    /// transitive edits through the library cache: editing XOR refreshes
    /// Half Adder's stored snapshot of XOR even though Half Adder's own
    /// file on disk didn't change. Returns true if any pin or snapshot
    /// value was rewritten, so the surrounding fixed-point loop knows when
    /// to stop iterating.
    @discardableResult
    static func refreshAllSnapshots(_ doc: inout CircuitDocument, libraryLookup: LibraryLookup) -> Bool {
        var didChange = false
        for i in doc.logic.components.indices {
            let comp = doc.logic.components[i]
            guard comp.kind == .subpart,
                  let filename = comp.partRef,
                  let libDoc = libraryLookup(filename)
            else { continue }
            let liveHash = libDoc.contentHash()
            // Compare deep state — `contentHash` strips partRefHash so two
            // versions of the same library with different inner pins would
            // look identical here and the loop would terminate early.
            let prevSnap = doc.librarySnapshots[liveHash]
            if comp.partRefHash != liveHash || prevSnap?.effectiveHash() != libDoc.effectiveHash() {
                doc.logic.components[i].partRefHash = liveHash
                doc.librarySnapshots[liveHash] = libDoc
                didChange = true
            }
        }
        return didChange
    }

    func encoded() throws -> Data {
        var copy = self
        copy.gcLibrarySnapshots()
        return try Self.jsonEncoder.encode(copy)
    }

    /// Drops `librarySnapshots` entries whose hash isn't referenced by any
    /// sub-part. Updating an instance to a newer library version replaces
    /// its pin — the old snapshot would otherwise linger forever, bloating
    /// the file every save.
    mutating func gcLibrarySnapshots() {
        let referenced = Set(logic.components.compactMap(\.partRefHash))
        librarySnapshots = librarySnapshots.filter { referenced.contains($0.key) }
    }

    /// Library lookup used by migrations to resolve a sub-part's referenced
    /// library document. Defined as a typealias rather than always going
    /// through `PartsLibrary.shared` so `PartsLibrary.reload()` can supply
    /// its own in-flight lookup — touching `PartsLibrary.shared` during
    /// reload re-enters dispatch_once and deadlocks.
    typealias LibraryLookup = (String) -> CircuitDocument?

    /// Default lookup used by every caller except `PartsLibrary.reload()`.
    /// Centralised so the deadlock-avoidance contract is visible.
    static let sharedLibraryLookup: LibraryLookup = { filename in
        PartsLibrary.shared.part(named: filename)?.document
    }

    static func decoded(
        from data: Data,
        libraryLookup: LibraryLookup = sharedLibraryLookup
    ) throws -> CircuitDocument {
        var doc = try jsonDecoder.decode(CircuitDocument.self, from: data)
        migrateInPlace(&doc, libraryLookup: libraryLookup)
        return doc
    }

    /// Forward-migrates a freshly decoded document. Keeps pin world positions
    /// (and therefore every route endpoint) invariant — geometry on screen
    /// after load is identical to what was written. The hash-population
    /// step is idempotent so callers can re-run it as more library files
    /// become resolvable (see `PartsLibrary.reload`'s fixed-point loop).
    /// Returns true if any new pin/snapshot was written, so callers can
    /// drive the loop without diffing the whole document.
    @discardableResult
    static func migrateInPlace(_ doc: inout CircuitDocument, libraryLookup: LibraryLookup = sharedLibraryLookup) -> Bool {
        if doc.schemaVersion < 2 {
            migrateSubpartAnchorsCenterToCorner(&doc, libraryLookup: libraryLookup)
        }
        let changed = populatePartRefHashes(&doc, libraryLookup: libraryLookup)
        doc.schemaVersion = currentSchemaVersion
        return changed
    }

    /// Pins each sub-part instance to its library's current content hash and
    /// embeds a snapshot. Idempotent: only fills components whose
    /// `partRefHash` is nil, and skips when the library file isn't resolvable
    /// from the supplied lookup. Recurses into existing `librarySnapshots`
    /// so a stale snapshot (saved before its own deps were pinnable) gets
    /// its inner pins filled in too — `contentHash()` strips `partRefHash`,
    /// so filling inner pins doesn't change the snapshot's hash and the
    /// parent's pin stays valid. Returns true if anything was written.
    @discardableResult
    static func populatePartRefHashes(_ doc: inout CircuitDocument, libraryLookup: LibraryLookup) -> Bool {
        var didWrite = false
        for i in doc.logic.components.indices {
            let comp = doc.logic.components[i]
            guard comp.kind == .subpart,
                  comp.partRefHash == nil,
                  let filename = comp.partRef,
                  let libDoc = libraryLookup(filename)
            else { continue }
            let hash = libDoc.contentHash()
            doc.logic.components[i].partRefHash = hash
            if doc.librarySnapshots[hash] == nil {
                doc.librarySnapshots[hash] = libDoc
            }
            didWrite = true
        }
        for key in doc.librarySnapshots.keys {
            var snap = doc.librarySnapshots[key]!
            if populatePartRefHashes(&snap, libraryLookup: libraryLookup) {
                doc.librarySnapshots[key] = snap
                didWrite = true
            }
        }
        return didWrite
    }

    /// v1 → v2: sub-part `Placement.position` previously stored the library
    /// outline's centre in parent-world; v2 stores its top-left corner. Shift
    /// each subpart placement by the rotated half-extent so world geometry
    /// stays put. Children whose library file isn't loaded yet are left alone
    /// — the same flag will trigger again next launch once the library is
    /// available (worst case: a permanently-missing part is treated as v2,
    /// which is harmless because the placeholder doesn't reference pins).
    private static func migrateSubpartAnchorsCenterToCorner(_ doc: inout CircuitDocument, libraryLookup: LibraryLookup) {
        // Snapshots aren't populated yet on a v1 file (that happens in the
        // v2→v3 step). Falling through to the supplied lookup is correct —
        // the v1 placements were saved against whatever was on disk at the
        // time, and the live library is the only available best-guess.
        for i in doc.physical.placements.indices {
            let placement = doc.physical.placements[i]
            guard let comp = doc.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let filename = comp.partRef,
                  let libDoc = libraryLookup(filename)
            else { continue }
            let outline = libDoc.physical.boardOutline
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
