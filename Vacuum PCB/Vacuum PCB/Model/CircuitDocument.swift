import Foundation
import CryptoKit

struct CircuitDocument: Codable, Hashable {
    /// v2: sub-part placements switched from centre-anchor to corner-anchor.
    /// v3: every sub-part instance pins a content hash of the library doc at
    /// placement / last-update time, and the parent document carries a
    /// snapshot dictionary keyed by that hash. Subpart resolution reads the
    /// snapshot, never the live library, so library edits don't cascade into
    /// saved designs. Migrations run transparently in `decoded(from:)`.
    /// v4: introduces `.connector` primitives — adds `connectorPinCount` /
    /// `connectorRole` to `Component`, `edgeAnchor` to `Placement`, and the
    /// `Edge` enum. All new fields are optional / decodeIfPresent, so v3
    /// docs round-trip unchanged with no explicit migration step.
    /// v5: introduces assembly mode — adds `matings: [Mating]` on
    /// `LogicGraph` and `ConnectorEndpoint`. The new field omits when empty
    /// (a non-assembly doc round-trips byte-identical), so v4 → v5 is a
    /// no-op for existing documents.
    /// v6: adds `connectorSignal` on `Component` — an electrical signal axis
    /// (`.input` / `.output` / `.bidirectional`) decoupled from the physical
    /// `connectorRole`, so a connector can act as a bidirectional bus. The
    /// field is optional and `decodeIfPresent`; a nil value derives the old
    /// role-based behaviour, so v5 → v6 is a no-op for existing documents.
    /// v7: adds `connectorPinNames` on `Component` — optional per-pin display
    /// names for a connector, indexed positionally. Optional / decodeIfPresent
    /// and nil for unnamed connectors, so v6 → v7 is a no-op for existing docs.
    /// v8: adds `skipEdgeWallDRC` — a per-document flag that suppresses the
    /// board-edge thin-wall DRC warnings for a design meant to be embedded as
    /// a sub-part (its outline isn't a real outer face). Optional / nil-default
    /// and omitted when off, so a v7 doc round-trips byte-identical and its
    /// content/effective hashes are unchanged (v7 → v8 is a no-op).
    /// v9: adds `connectorScrewCount` on `Component` — the number of clamp
    /// screws on a connector. Optional / decodeIfPresent and nil for the
    /// legacy "two end caps" layout, so v8 → v9 is a no-op for existing docs.
    /// v10: adds `testPoints` on `PhysicalLayout` — physical-view probe taps
    /// that bore vertically from a route segment to the plate's outer face.
    /// The array omits when empty and decodes with `decodeIfPresent ?? []`, so
    /// a v9 doc round-trips byte-identical (v9 → v10 is a no-op). Test-point
    /// geometry participates in the content/effective hashes (it changes the
    /// printed plate) but the cosmetic `name` is stripped so renames don't
    /// churn library snapshots.
    static let currentSchemaVersion = 10

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
    /// Marks this design as a reusable sub-component whose `boardOutline` is
    /// not a real outer face (it gets embedded inside a larger plate). When
    /// set, DRC skips the board-edge thin-wall warnings (`thinWall(.outerFace)`)
    /// for *this* document only — internal channel/bore wall checks still run.
    /// The flag never propagates: `DRC.thinWallIssues` runs on the unflattened
    /// top-level doc and never reads `librarySnapshots`, so any design that
    /// embeds this part re-checks its own edges with its own flag. Optional /
    /// nil-default and stripped from `contentHash`/`effectiveHash`, so toggling
    /// it is a pure annotation that never churns snapshot keys or staleness.
    var skipEdgeWallDRC: Bool?
    /// Optional Simulate-tab test suite: the DSL script (see `TestDSL`) the user
    /// pasted/edited for this design, persisted so reopening the file restores
    /// it. A pure annotation with no geometric/logical/behavioural effect, so it
    /// is excluded from `contentHash`/`effectiveHash` (storing or editing tests
    /// never re-pins a parent's snapshot or flags "library has changes") *and*
    /// from `==`/`hash` (a keystroke in the test editor must not churn the
    /// preview, validation, or the live sim network — `SimulateView` rebuilds
    /// the network on any `document.circuit` change). Optional / nil-default /
    /// `decodeIfPresent` and omitted when nil, so it needs no schema bump: a doc
    /// without tests round-trips byte-identical and an older build ignores the key.
    var tests: String?

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        manufacturing: ManufacturingConstants = .defaults,
        logic: LogicGraph,
        schematic: SchematicLayout = .empty,
        physical: PhysicalLayout,
        librarySnapshots: [String: CircuitDocument] = [:],
        skipEdgeWallDRC: Bool? = nil,
        tests: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.manufacturing = manufacturing
        self.logic = logic
        self.schematic = schematic
        self.physical = physical
        self.librarySnapshots = librarySnapshots
        self.skipEdgeWallDRC = skipEdgeWallDRC
        self.tests = tests
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, manufacturing, logic, schematic, physical, librarySnapshots
        case skipEdgeWallDRC, tests
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
        // v8: absent in v7-and-earlier files; nil means "off" everywhere.
        self.skipEdgeWallDRC = try c.decodeIfPresent(Bool.self, forKey: .skipEdgeWallDRC)
        // Optional test-suite annotation; absent in files that never stored one.
        self.tests = try c.decodeIfPresent(String.self, forKey: .tests)
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
        flattenedWithLabels(visiting: [], prefix: nil).doc
    }

    /// Recursive worker for `flattened()`. `visiting` holds the chain of
    /// library filenames currently being expanded; a subpart whose `partRef`
    /// is already in that set is skipped (cycle).
    func flattened(visiting: Set<String>) -> CircuitDocument {
        flattenedWithLabels(visiting: visiting, prefix: nil).doc
    }

    /// Same as `flattened()` but also returns a `[routeNetId → label]` map.
    /// Parent-level routes get their net's own label (e.g., "n9"); routes
    /// hoisted out of a sub-part instance are prefixed with the instance
    /// chain (e.g., "U1.n3", "U1.U2.n5"). DRC uses this to attribute a
    /// cross-net merge to the originating sub-part net by name — without
    /// the prefix the user couldn't tell which net inside which instance
    /// is colliding.
    func flattenedWithLabels() -> (doc: CircuitDocument, routeLabels: [UUID: String]) {
        flattenedWithLabels(visiting: [], prefix: nil)
    }

    private func flattenedWithLabels(
        visiting: Set<String>, prefix: String?
    ) -> (doc: CircuitDocument, routeLabels: [UUID: String]) {
        var labels: [UUID: String] = [:]
        var ownNetLabels: [UUID: String] = [:]
        for net in self.logic.nets {
            ownNetLabels[net.id] = prefix.map { "\($0).\(net.label)" } ?? net.label
        }
        for route in self.physical.routes {
            labels[route.netId] = ownNetLabels[route.netId] ?? "?"
        }

        // Fast path: a document with no sub-parts to expand and no matings to
        // merge already *is* its own flattening, so skip the (allocation-heavy)
        // rebuild entirely. This is the common case, and it's hit hard — DRC's
        // cross-net-merge check flattens on every `DRC.check`, which the
        // minimiser runs once per trial. Measured as a top cost in profiling.
        if logic.matings.isEmpty,
           !logic.components.contains(where: { $0.kind == .subpart }) {
            return (self, labels)
        }

        var primitives = self
        var components = primitives.logic.components.filter { $0.kind != .subpart }
        var placements: [Placement] = primitives.physical.placements.filter { p in
            self.logic.components.first(where: { $0.id == p.componentId })?.kind != .subpart
        }
        var routes = primitives.physical.routes
        // Depth-1 connector address map: (parent's subpart component id,
        // connector component id inside the subpart's library snapshot) →
        // the freshly-minted UUID assigned when expanding that connector
        // into the flat doc. Used at the end of flatten to resolve
        // `Mating` endpoints. Deeper-than-one-level connectors aren't
        // tracked because the Mating endpoint scheme can't address them
        // — by design in V1 of assembly mode.
        var socketIds: [SocketKey: UUID] = [:]

        for placement in self.physical.placements {
            guard let comp = self.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .subpart,
                  let filename = comp.partRef,
                  !visiting.contains(filename),
                  let part = comp.resolvedPart(snapshots: self.librarySnapshots),
                  // Subparts that are themselves assemblies (have matings of
                  // their own) can't be expanded yet — V1 of assembly mode
                  // is one level deep. Skip the placement; the canvas
                  // surfaces it as a placeholder like the missing-part /
                  // cycle cases.
                  part.document.logic.matings.isEmpty
            else { continue }

            // Pre-flatten the child so any subparts inside it are already
            // expanded to primitives in the child's coordinate system. The
            // parent then only needs a single rotation/translation step.
            let childPrefix = prefix.map { "\($0).\(comp.label)" } ?? comp.label
            let (childFlat, childLabels) = part.document.flattenedWithLabels(
                visiting: visiting.union([filename]),
                prefix: childPrefix
            )

            // Boundary-pin net unification: for each parent net that has a
            // PinRef into this sub-part instance, find the matching boundary
            // component inside the library doc, then the sub-part's interior
            // net that contains that boundary component. Map: interior net id
            // → parent net id. Hoisted routes on those interior nets adopt
            // the parent's net id instead of a fresh UUID — so DRC's
            // cross-net-merge check doesn't mistake the intended channel-meeting
            // at the boundary pin for an electrical short between distinct
            // nets.
            var netUnification: [UUID: UUID] = [:]
            for parentNet in self.logic.nets {
                for parentPin in parentNet.pins where parentPin.componentId == comp.id {
                    guard let boundaryUUID = UUID(uuidString: parentPin.pinKey) else { continue }
                    if let interiorNet = part.document.logic.nets.first(where: { interior in
                        interior.pins.contains(where: { $0.componentId == boundaryUUID })
                    }) {
                        netUnification[interiorNet.id] = parentNet.id
                    }
                }
            }

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
                    depth: internalPlacement.depth,
                    edgeAnchor: internalPlacement.edgeAnchor
                ))
                components.append(Component(
                    id: newId,
                    kind: internalComp.kind,
                    label: "\(comp.label).\(internalComp.label)",
                    resistorSize: internalComp.resistorSize,
                    portDirection: internalComp.portDirection,
                    connectorPinCount: internalComp.connectorPinCount,
                    connectorScrewCount: internalComp.connectorScrewCount,
                    connectorRole: internalComp.connectorRole
                ))
                if internalComp.kind == .connector {
                    // Record the parent → flattened mapping for any Mating
                    // endpoints that reference this socket. The library's
                    // own connector UUID is preserved through flatten (only
                    // subparts get re-IDd), so `internalComp.id` is the
                    // value the Mating endpoint carries.
                    socketIds[SocketKey(subpartId: comp.id, connectorId: internalComp.id)] = newId
                }
            }

            // Internal routes. NetId is normally regenerated to avoid
            // colliding with parent nets — except for interior nets that
            // unify with a parent net through a boundary pin (see
            // `netUnification` above), where we deliberately reuse the
            // parent's net id so they read as one electrical net downstream.
            //
            // Key invariant: all routes that shared a netId inside the
            // sub-part must share a single new netId after flatten too.
            // Minting per-route would split one logical net into N
            // unrelated-looking nets, and the cross-net-merge DRC check
            // would then flag every same-net route pair as a phantom short.
            var newNetIds: [UUID: UUID] = [:]
            for route in childFlat.physical.routes where newNetIds[route.netId] == nil {
                newNetIds[route.netId] = netUnification[route.netId] ?? UUID()
            }
            for route in childFlat.physical.routes {
                let newSegments = route.segments.map { seg -> Segment in
                    let newWaypoints = seg.waypoints.map {
                        Waypoint(position: toWorld($0.position), kind: $0.kind)
                    }
                    return Segment(waypoints: newWaypoints, layer: seg.layer)
                }
                routes.append(Route(netId: newNetIds[route.netId]!, segments: newSegments))
            }
            for (origId, newId) in newNetIds where netUnification[origId] == nil {
                labels[newId] = childLabels[origId] ?? "?"
            }
        }

        primitives.logic.components = components
        primitives.physical.placements = placements
        primitives.physical.routes = routes

        // Apply matings: for each pin pair (i in 1...N) of the two mated
        // connectors, merge their nets so the simulator and DRC see a
        // joined network. Unresolvable endpoints (subpart placement gone,
        // connector id stale, mismatched pin counts) are silently skipped
        // here — DRC surfaces those as user-visible issues against the
        // unflattened doc.
        primitives.logic.matings = []
        for mating in self.logic.matings {
            guard let aId = Self.resolveEndpoint(mating.a, socketIds: socketIds),
                  let bId = Self.resolveEndpoint(mating.b, socketIds: socketIds),
                  aId != bId,
                  let aComp = primitives.logic.components.first(where: { $0.id == aId }),
                  let bComp = primitives.logic.components.first(where: { $0.id == bId }),
                  aComp.kind == .connector,
                  bComp.kind == .connector
            else { continue }
            let n = min(aComp.connectorPinCount ?? 0, bComp.connectorPinCount ?? 0)
            guard n > 0 else { continue }
            for i in 1...n {
                let a = PinRef(componentId: aId, pinKey: "\(i)")
                let b = PinRef(componentId: bId, pinKey: "\(i)")
                Self.mergePinsAtFlatten(&primitives, a, b)
            }
        }

        return (primitives, labels)
    }

    /// Two-tuple key used during flatten to remember which subpart-internal
    /// connector got which freshly-minted UUID. Mating endpoints carrying
    /// the same subpart + connector ids resolve through this map.
    private struct SocketKey: Hashable {
        let subpartId: UUID
        let connectorId: UUID
    }

    private static func resolveEndpoint(
        _ endpoint: ConnectorEndpoint,
        socketIds: [SocketKey: UUID]
    ) -> UUID? {
        switch endpoint {
        case .topLevel(let id):
            return id
        case .subpartSocket(let sid, let cid):
            return socketIds[SocketKey(subpartId: sid, connectorId: cid)]
        }
    }

    /// Route-preserving net merge for flatten-time mating expansion.
    ///
    /// `connectPins` (the schematic-editor entry point) deletes the
    /// "loser" net's routes when merging — appropriate for the wire-two-pins
    /// flow where the user is collapsing two empty-route nets into one.
    /// At flatten we want the opposite: any routes that already came along
    /// for the ride from a subpart should retain their geometry and just
    /// adopt the surviving net's id.
    private static func mergePinsAtFlatten(_ doc: inout CircuitDocument, _ first: PinRef, _ second: PinRef) {
        guard first != second else { return }
        var nets = doc.logic.nets
        let firstIdx = nets.firstIndex { $0.pins.contains(first) }
        let secondIdx = nets.firstIndex { $0.pins.contains(second) }
        switch (firstIdx, secondIdx) {
        case (nil, nil):
            nets.append(Net(label: "mated", pins: [first, second]))
        case (let i?, nil):
            nets[i].pins.append(second)
        case (nil, let j?):
            nets[j].pins.append(first)
        case (let i?, let j?) where i == j:
            break
        case (let a?, let b?):
            let i = min(a, b), j = max(a, b)
            let survivingId = nets[i].id
            let killedId = nets[j].id
            nets[i].pins.append(contentsOf: nets[j].pins.filter { !nets[i].pins.contains($0) })
            nets.remove(at: j)
            for r in doc.physical.routes.indices where doc.physical.routes[r].netId == killedId {
                doc.physical.routes[r].netId = survivingId
            }
        }
        doc.logic.nets = nets
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
        // nil and false are the same "off" state — normalise so the two
        // never read as distinct documents (would spuriously mark dirty).
        hasher.combine(skipEdgeWallDRC ?? false)
    }

    static func == (lhs: CircuitDocument, rhs: CircuitDocument) -> Bool {
        lhs.schemaVersion == rhs.schemaVersion
            && lhs.manufacturing == rhs.manufacturing
            && lhs.logic == rhs.logic
            && lhs.schematic == rhs.schematic
            && lhs.physical == rhs.physical
            && (lhs.skipEdgeWallDRC ?? false) == (rhs.skipEdgeWallDRC ?? false)
    }
}

extension CircuitDocument {
    /// True when this document has any `.connector` primitive in its logic
    /// graph. Used by DRC and the schematic palette: dropping a
    /// connector-bearing part into a non-assembly document needs a
    /// confirmation prompt, since adding it flips the document into
    /// assembly mode.
    var containsConnector: Bool {
        logic.components.contains(where: { $0.kind == .connector })
    }

    /// True when this document is in **assembly mode** — derived from the
    /// presence of any subpart whose library snapshot contains a connector
    /// primitive. Mating those connectors via `LogicGraph.matings` is the
    /// raison-d'être of an assembly. In assembly mode the Physical and
    /// 3D Preview tabs are gated off and the Simulate physical-canvas is
    /// hidden — the document is a schematic + simulation product.
    var isAssembly: Bool {
        for c in logic.components where c.kind == .subpart {
            guard let part = c.resolvedPart(snapshots: librarySnapshots) else { continue }
            if part.document.containsConnector { return true }
        }
        return false
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
    ///  - `skipEdgeWallDRC` (a per-doc DRC display preference with no
    ///    geometric/behavioural effect — stripping to nil keeps the key
    ///    byte-identical to a v7 doc so upgrading never re-hashes the library,
    ///    and toggling the flag never re-pins a parent's snapshot)
    /// Used as the snapshot-dict key. For staleness comparison — does this
    /// doc behave differently than another doc, including via transitive
    /// dependency changes — use `effectiveHash()` instead.
    func contentHash() -> String {
        var stripped = self
        stripped.librarySnapshots = [:]
        stripped.schemaVersion = 0
        stripped.skipEdgeWallDRC = nil
        stripped.tests = nil
        for i in stripped.logic.components.indices {
            stripped.logic.components[i].partRefHash = nil
        }
        // Test-point *geometry* changes the printed plate, so it stays in the
        // hash — but the cosmetic `name` doesn't, so strip it (like `tests`)
        // to keep renaming a test point from re-pinning library snapshots.
        for i in stripped.physical.testPoints.indices {
            stripped.physical.testPoints[i].name = ""
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
        // No flatten/CAD effect, so it can't make this doc behave differently —
        // exclude it (matches `contentHash`) to avoid phantom staleness.
        stripped.skipEdgeWallDRC = nil
        stripped.tests = nil
        // See `contentHash()` — test-point geometry counts, its name doesn't.
        for i in stripped.physical.testPoints.indices {
            stripped.physical.testPoints[i].name = ""
        }
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

    /// Wire two pins on the schematic. Both tap-to-tap and drag-to-pin
    /// flows commit through here so the four pin/net states (neither on a
    /// net, one on a net, on different nets, on the same net) only need
    /// one implementation:
    ///   * neither on a net → create a new net with both,
    ///   * one on a net → add the other to it,
    ///   * different nets → merge the higher-index into the lower,
    ///   * same net → toggle: remove the second; drop the net if it
    ///     falls below two pins.
    /// In every removal case the associated physical routes are deleted
    /// so a dead net doesn't leak orphan segments.
    mutating func connectPins(_ first: PinRef, _ second: PinRef) {
        guard first != second else { return }
        var nets = logic.nets
        let firstIdx = nets.firstIndex { $0.pins.contains(first) }
        let secondIdx = nets.firstIndex { $0.pins.contains(second) }

        switch (firstIdx, secondIdx) {
        case (nil, nil):
            let label = logic.nextNetLabel()
            nets.append(Net(label: label, pins: [first, second]))
        case (let i?, nil):
            nets[i].pins.append(second)
        case (nil, let j?):
            nets[j].pins.append(first)
        case (let i?, let j?) where i == j:
            nets[i].pins.removeAll { $0 == second }
            if nets[i].pins.count < 2 {
                let killedNetId = nets[i].id
                nets.remove(at: i)
                physical.routes.removeAll { $0.netId == killedNetId }
            }
        case (let a?, let b?):
            let i = min(a, b), j = max(a, b)
            let merged = nets[j].pins
            nets[i].pins.append(contentsOf: merged.filter { !nets[i].pins.contains($0) })
            let killedNetId = nets[j].id
            nets.remove(at: j)
            physical.routes.removeAll { $0.netId == killedNetId }
        }
        logic.nets = nets
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
