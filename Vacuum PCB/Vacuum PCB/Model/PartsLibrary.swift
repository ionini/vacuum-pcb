import Foundation
import SwiftUI
import Combine

/// Which side of a sub-part's symbol a boundary pin is placed on. Inferred
/// from where the corresponding boundary component sits inside the library
/// file's own schematic — projects the schematic position onto the closest
/// edge of the schematic bounding box and orders pins along that edge.
enum SymbolSide: String, Hashable {
    case left, right, top, bottom
}

/// One externally-visible pin of a library part: the matching component's
/// stable UUID, its label, where it lives on the auto-generated symbol, and
/// its physical-side anchor inside the library's coordinate system.
///
/// Pins come from two sources:
///   * `.port` components (signal I/O).
///   * `.vacuumSource` / `.atmVent` components (power rails — exposed as pins
///     per the v1 design so the parent can wire its own rails to the instance,
///     rather than auto-merging by net label).
struct BoundaryPin: Hashable {
    /// UUID of the boundary component inside the library document. Used as
    /// the `pinKey` on parent-side `PinRef`s so renames don't break links.
    let portId: UUID
    let label: String
    let kind: ComponentKind
    /// Side of the auto-generated schematic symbol this pin sits on.
    let side: SymbolSide
    /// Order along its side, top-to-bottom or left-to-right.
    let orderOnSide: Int
    /// Physical-side anchor (millimetres) in the library's coordinate system.
    /// Comes from the matching Placement's `worldPosition(of: "p")`.
    let physicalAnchor: Point
    /// Physical resolved plate of the boundary component inside the library.
    /// We don't constrain the parent's plate — the marker is layer-agnostic —
    /// but the library plate is still useful info for inspector tooltips.
    let plate: Plate
    /// Depth of the boundary component inside the library (channel-layer index
    /// on `plate`). Carried alongside `plate` so the parent can resolve the
    /// pin's full `Layer` — without this, routes started from a sub-part's
    /// outlet default to depth 0 regardless of where the underlying library
    /// port actually sits.
    let depth: Int
}

/// User-global library of reusable parts. One folder under Application
/// Support, scanned at launch (and on `reload()`). Library files may
/// themselves contain `.subpart` instances — nested hierarchies expand
/// recursively at flatten / render time. Reference cycles between files
/// are tolerated at load and broken at use site with a placeholder.
///
/// Lookup is by filename (no UUID inside the library file). Renaming a
/// library file breaks every parent that references it — by design, matches
/// the v1 reference-model decision.
final class PartsLibrary: ObservableObject {
    static let shared = PartsLibrary()

    /// User-visible parts folder. Created on first launch.
    static var folderURL: URL {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Vacuum PCB/Parts", isDirectory: true)
    }

    struct Part: Identifiable, Hashable {
        let filename: String
        let document: CircuitDocument
        let pins: [BoundaryPin]
        var id: String { filename }

        /// User-facing display name: filename without the `.vpcb` extension.
        var displayName: String {
            if filename.lowercased().hasSuffix(".vpcb") {
                return String(filename.dropLast(5))
            }
            return filename
        }
    }

    @Published private(set) var parts: [Part] = []
    @Published private(set) var lastError: String?

    private init() {
        reload()
    }

    func reload() {
        let url = Self.folderURL
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        }
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            parts = []
            return
        }
        // Migration during reload MUST NOT reach into `PartsLibrary.shared`
        // — we're inside its dispatch_once initialiser. Library files
        // referencing each other resolve against this in-flight dict
        // instead.
        var inFlight: [String: CircuitDocument] = [:]
        let inFlightLookup: CircuitDocument.LibraryLookup = { inFlight[$0] }

        // First pass: decode + initial migration. Files iterated before
        // their dependencies will leave partRefHash nil for the dependency
        // — the fixed-point loop below fills those in once everyone is
        // loaded.
        for entry in entries where entry.pathExtension.lowercased() == "vpcb" {
            guard let data = try? Data(contentsOf: entry) else { continue }
            guard let doc = try? CircuitDocument.decoded(from: data, libraryLookup: inFlightLookup) else { continue }
            inFlight[entry.lastPathComponent] = doc
        }

        // Fixed-point fill-in: each pass can only ADD partRefHashes (the
        // populator is monotone), so this terminates in at most N passes
        // where N is the longest dependency chain. The `+ 1` bound keeps
        // it linear in the file count even for the worst case.
        for _ in 0...inFlight.count {
            var changed = false
            for (filename, var doc) in inFlight {
                if CircuitDocument.populatePartRefHashes(&doc, libraryLookup: inFlightLookup) {
                    inFlight[filename] = doc
                    changed = true
                }
            }
            if !changed { break }
        }

        // Force-refresh pass: unconditionally re-pin every subpart to the
        // current library doc. The fill-in step above only writes nil
        // pins — files whose on-disk pin is stale (e.g., Half Adder
        // pinned to an XOR version that's since been edited) wouldn't be
        // caught. This loop propagates transitive edits through the
        // library cache so a single edit to XOR.vpcb flows up through
        // Half Adder → Incrementor in memory before any design opens.
        for _ in 0...inFlight.count {
            var changed = false
            for (filename, var doc) in inFlight {
                if CircuitDocument.refreshAllSnapshots(&doc, libraryLookup: inFlightLookup) {
                    inFlight[filename] = doc
                    changed = true
                }
            }
            if !changed { break }
        }

        // Build the final `Part` list now that every doc has converged.
        var collected: [Part] = []
        for (filename, doc) in inFlight {
            collected.append(Part(filename: filename, document: doc, pins: Self.boundaryPins(in: doc)))
        }
        // Stable order so the palette doesn't reshuffle on every reload.
        collected.sort { $0.filename.localizedCompare($1.filename) == .orderedAscending }
        parts = collected
    }

    func part(named filename: String) -> Part? {
        parts.first(where: { $0.filename == filename })
    }

    /// Public so call sites that already hold a fresh library document (e.g.
    /// a missing-part placeholder fed a cached doc) can compute pins without
    /// going through `parts`.
    static func boundaryPins(in doc: CircuitDocument) -> [BoundaryPin] {
        // 1. Schematic bbox over every component with a position. Falls back to
        //    [0,0,1,1] if the library lacks any schematic layout.
        var positions: [(Component, Point)] = []
        for c in doc.logic.components {
            guard let p = doc.schematic.position(for: c.id) else { continue }
            positions.append((c, p))
        }
        let minX = positions.map { $0.1.x }.min() ?? 0
        let maxX = positions.map { $0.1.x }.max() ?? 1
        let minY = positions.map { $0.1.y }.min() ?? 0
        let maxY = positions.map { $0.1.y }.max() ?? 1
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2

        struct Provisional {
            let portId: UUID
            let label: String
            let kind: ComponentKind
            let side: SymbolSide
            let along: Double  // ordering coord along the chosen side
            let physicalAnchor: Point
            let plate: Plate
            let depth: Int
        }

        var rough: [Provisional] = []
        for c in doc.logic.components {
            guard c.kind == .port || c.kind == .vacuumSource || c.kind == .atmVent else { continue }
            let pos = doc.schematic.position(for: c.id) ?? Point(x: cx, y: cy)
            let placement = doc.physical.placements.first(where: { $0.componentId == c.id })
            // Anchor for the pin in the library's physical coordinates: the
            // boundary component's pin "p" world position. For instance pin
            // markers we transform this into the parent's frame at render time.
            let anchor: Point
            let plate: Plate
            let depth: Int
            if let placement {
                let fp = c.kind.footprint(manufacturing: doc.manufacturing)
                if let pin = fp.pins.first {
                    anchor = placement.worldPosition(of: pin)
                } else {
                    anchor = placement.position
                }
                plate = placement.layer
                depth = placement.depth
            } else {
                anchor = .zero
                plate = .top
                depth = 0
            }

            // Project onto nearest edge. Inputs (ports) lean left; outputs
            // lean right; rails (VAC, VENT) lean top/bottom. Schematic
            // position breaks ties.
            let dxLeft = pos.x - minX
            let dxRight = maxX - pos.x
            let dyTop = pos.y - minY
            let dyBottom = maxY - pos.y
            var side: SymbolSide = [
                (SymbolSide.left, dxLeft),
                (SymbolSide.right, dxRight),
                (SymbolSide.top, dyTop),
                (SymbolSide.bottom, dyBottom),
            ].min(by: { $0.1 < $1.1 })!.0

            // Heuristic overrides: input ports always go on the left,
            // outputs on the right. Rails default to top/bottom so VAC/VENT
            // don't fight signal pins for the side rails. Only override when
            // the user hasn't put strong intent in the schematic layout.
            if c.kind == .port {
                if c.portDirection == .input { side = .left }
                if c.portDirection == .output { side = .right }
            } else if c.kind == .vacuumSource && side != .left && side != .right {
                side = .top
            } else if c.kind == .atmVent && side != .left && side != .right {
                side = .bottom
            }

            let along: Double
            switch side {
            case .left, .right: along = pos.y
            case .top, .bottom: along = pos.x
            }
            rough.append(Provisional(
                portId: c.id, label: c.label, kind: c.kind,
                side: side, along: along, physicalAnchor: anchor,
                plate: plate, depth: depth
            ))
        }

        // Order along each side, then assign indices.
        var pins: [BoundaryPin] = []
        for side in [SymbolSide.left, .right, .top, .bottom] {
            let group = rough.filter { $0.side == side }.sorted { $0.along < $1.along }
            for (i, p) in group.enumerated() {
                pins.append(BoundaryPin(
                    portId: p.portId, label: p.label, kind: p.kind,
                    side: side, orderOnSide: i,
                    physicalAnchor: p.physicalAnchor,
                    plate: p.plate, depth: p.depth
                ))
            }
        }
        return pins
    }

    /// Helper for filename-based lookup that doesn't crash on missing parts —
    /// callers handle the optional themselves.
    func boundaryPins(named filename: String) -> [BoundaryPin]? {
        part(named: filename)?.pins
    }

    /// Snapshot-first resolution for a sub-part instance. Returns the frozen
    /// library document from the parent's `librarySnapshots` when the
    /// component has a pinned hash that matches an entry; falls back to the
    /// live on-disk library otherwise. The fallback path matters in two
    /// cases: (1) a sub-part whose v2→v3 migration ran without the library
    /// present, and (2) defensive callers that don't have a snapshots dict
    /// handy (passing `[:]`).
    static func resolve(
        partRef filename: String,
        hash: String?,
        snapshots: [String: CircuitDocument]
    ) -> Part? {
        if let hash, let doc = snapshots[hash] {
            return Part(
                filename: filename,
                document: doc,
                pins: cachedBoundaryPins(forHash: hash, in: doc)
            )
        }
        return shared.part(named: filename)
    }

    // MARK: - Boundary-pin cache
    //
    // `boundaryPins(in:)` scans every component + placement in the snapshot
    // and was the dominant CPU cost during schematic pan/zoom (profile:
    // 89/390 user-code samples). Every subpart instance hit it from
    // `resolvedPart` on every SwiftUI body invalidation — multiple times per
    // render because both `ComponentSymbolView` and `ComponentNodeView`
    // recompute their `metrics` computed property in a ForEach. Pins are a
    // pure function of the snapshot, so we memoise by `contentHash` (the
    // same key the snapshot dict uses). Entries are immortal-ish: editing a
    // library part produces a new hash, the old entry simply never matches
    // again. Locked because some non-UI callers (DRC, flatten, CAD) reach
    // `resolve` off the main thread.
    private static let pinsCacheLock = NSLock()
    private static var pinsCache: [String: [BoundaryPin]] = [:]

    static func cachedBoundaryPins(forHash hash: String, in doc: CircuitDocument) -> [BoundaryPin] {
        pinsCacheLock.lock()
        if let cached = pinsCache[hash] {
            pinsCacheLock.unlock()
            return cached
        }
        pinsCacheLock.unlock()
        let pins = boundaryPins(in: doc)
        pinsCacheLock.lock()
        pinsCache[hash] = pins
        pinsCacheLock.unlock()
        return pins
    }
}

extension Component {
    /// Snapshot-first lookup for this sub-part instance. `nil` for non-subpart
    /// kinds, components with no `partRef`, or when both the snapshot and the
    /// live library are missing.
    func resolvedPart(snapshots: [String: CircuitDocument]) -> PartsLibrary.Part? {
        guard kind == .subpart, let filename = partRef else { return nil }
        return PartsLibrary.resolve(partRef: filename, hash: partRefHash, snapshots: snapshots)
    }
}

// Library snapshots flow from the open document down through every view that
// needs to resolve a sub-part reference. SwiftUI's environment avoids
// threading a parameter through dozens of intermediate views — the
// `DocumentView` sets the value once per open document and every subpart
// lookup site reads it.
private struct LibrarySnapshotsKey: EnvironmentKey {
    static let defaultValue: [String: CircuitDocument] = [:]
}

extension EnvironmentValues {
    var librarySnapshots: [String: CircuitDocument] {
        get { self[LibrarySnapshotsKey.self] }
        set { self[LibrarySnapshotsKey.self] = newValue }
    }
}
