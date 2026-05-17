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
        var collected: [Part] = []
        for entry in entries where entry.pathExtension.lowercased() == "vpcb" {
            guard let data = try? Data(contentsOf: entry) else { continue }
            guard let doc = try? CircuitDocument.decoded(from: data) else { continue }
            let pins = Self.boundaryPins(in: doc)
            collected.append(Part(filename: entry.lastPathComponent, document: doc, pins: pins))
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
}
