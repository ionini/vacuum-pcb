import SwiftUI
import Combine

/// In-app clipboard for the schematic editor. Holds a snapshot of one or more
/// copied components together with the connectivity that lives *entirely*
/// among them (net fragments + wire waypoints) and any library snapshots the
/// copied subparts reference, so a paste can rebuild the sub-circuit — even
/// into a different open document.
///
/// It's an `ObservableObject` singleton so the inspector's Paste button can
/// light up the moment something is copied (the macOS ⌘C/⌘V path mutates the
/// same instance). The payload is same-app in-memory only — there's no
/// `NSPasteboard` bridge, so it doesn't survive relaunches or cross-app copy.
final class SchematicClipboard: ObservableObject {
    static let shared = SchematicClipboard()

    /// One copied component plus the schematic layout needed to place it.
    struct Item {
        var component: Component
        /// Absolute schematic position at copy time. Paste offsets the whole
        /// group by a fixed step so the copy doesn't land on top of the source.
        var position: Point
        var rotation: Int
    }

    struct Payload {
        var items: [Item]
        /// Every net that touches the copied set, stored as its *full* pin
        /// list (internal + external). Paste remaps the internal pins and, for
        /// external pins that are shared rails (VAC/ATM), reconnects the copy
        /// to the same rail — so copying a transistor wired to ATM keeps that
        /// tie without having to select the vent.
        var nets: [[PinRef]]
        /// Wire waypoints whose pin pair is fully inside the copied set.
        var waypoints: [WireWaypoints]
        /// Library snapshots for any copied subparts, so paste into a document
        /// that doesn't already have them can register the reference.
        var snapshots: [String: CircuitDocument]
    }

    @Published private(set) var payload: Payload?

    /// How many times the current payload has been pasted. Reset on copy so a
    /// fresh copy pastes at the first offset again.
    private var pasteCount = 0

    var hasContent: Bool { payload != nil }

    func store(_ payload: Payload) {
        self.payload = payload
        pasteCount = 0
    }

    /// Advances and returns the schematic offset for the next paste, so
    /// repeated ⌘V (or Paste taps) cascade down-right instead of stacking.
    func nextPasteOffset() -> Double {
        pasteCount += 1
        return SchematicLayout.gridStep * 2 * Double(pasteCount)
    }
}

// MARK: - Copy / cut / paste mutations

extension SchematicActions {
    /// Snapshots the selected components (and the wiring internal to them)
    /// into the shared clipboard. Reads the document by value — no mutation.
    /// A net that straddles the selection boundary contributes only its
    /// internal pins; a net with fewer than two internal pins is dropped.
    static func copy(document: VPCBDocument, selection: SchematicSelection) {
        let ids = selection.components
        guard !ids.isEmpty else { return }

        var items: [SchematicClipboard.Item] = []
        for component in document.circuit.logic.components where ids.contains(component.id) {
            let pos = document.circuit.schematic.position(for: component.id)
                ?? Point(x: 200, y: 200)
            let rot = document.circuit.schematic.rotation(for: component.id)
            items.append(.init(component: component, position: pos, rotation: rot))
        }
        guard !items.isEmpty else { return }

        // Every net with at least one pin on a copied component, stored whole.
        // Classification into internal / external-rail happens at paste time.
        var nets: [[PinRef]] = []
        for net in document.circuit.logic.nets
        where net.pins.contains(where: { ids.contains($0.componentId) }) {
            nets.append(net.pins)
        }

        // Waypoints whose wire lives entirely inside the selection.
        var waypoints: [WireWaypoints] = []
        for entry in document.circuit.schematic.wireWaypoints ?? [] {
            if ids.contains(entry.pair.a.componentId),
               ids.contains(entry.pair.b.componentId) {
                waypoints.append(entry)
            }
        }

        // Library snapshots for copied subparts.
        var snapshots: [String: CircuitDocument] = [:]
        for item in items where item.component.kind == .subpart {
            if let hash = item.component.partRefHash,
               let snap = document.circuit.librarySnapshots[hash] {
                snapshots[hash] = snap
            }
        }

        SchematicClipboard.shared.store(SchematicClipboard.Payload(
            items: items, nets: nets, waypoints: waypoints, snapshots: snapshots
        ))
    }

    /// Copy the selection, then delete it (the standard cut).
    static func cut(document: inout VPCBDocument, selection: inout SchematicSelection) {
        copy(document: document, selection: selection)
        delete(document: &document, selection: &selection)
    }

    /// Instantiate the clipboard payload into the document with fresh UUIDs and
    /// unique labels, offset down-right from the originals, and select the
    /// result. Every reference (net pins, wire waypoints) is remapped through a
    /// `[oldId: newId]` table so the pasted sub-circuit is self-contained.
    /// No-op when the clipboard is empty.
    static func paste(document: inout VPCBDocument, selection: inout SchematicSelection) {
        guard let payload = SchematicClipboard.shared.payload, !payload.items.isEmpty
        else { return }
        let delta = SchematicClipboard.shared.nextPasteOffset()

        var remap: [UUID: UUID] = [:]
        var pasted: Set<UUID> = []

        for item in payload.items {
            let newId = UUID()
            remap[item.component.id] = newId

            var component = item.component
            component.id = newId
            component.label = document.circuit.logic.nextLabel(
                for: component.kind, portDirection: component.portDirection)

            // Ensure a copied subpart's library snapshot exists in this doc.
            if component.kind == .subpart, let hash = component.partRefHash,
               document.circuit.librarySnapshots[hash] == nil,
               let snap = payload.snapshots[hash] {
                document.circuit.librarySnapshots[hash] = snap
            }

            document.circuit.logic.components.append(component)

            let pos = SchematicLayout.snapToGrid(
                Point(x: item.position.x + delta, y: item.position.y + delta))
            document.circuit.schematic.setPosition(pos, for: newId)
            if item.rotation != 0 {
                document.circuit.schematic.rotate(componentId: newId, by: item.rotation)
            }

            // Subparts carry an eager centred physical placement (mirrors
            // `commitLibraryPart`); primitives get a placement lazily from the
            // physical canvas, so paste leaves them placement-less like a
            // fresh palette add.
            if component.kind == .subpart {
                let outline = document.circuit.physical.boardOutline
                let centre = Point(
                    x: outline.origin.x + outline.size.width / 2,
                    y: outline.origin.y + outline.size.height / 2
                )
                document.circuit.physical.placements.append(
                    Placement(componentId: newId, position: centre,
                              rotation: .r0, layer: .top, depth: 0)
                )
            }

            pasted.insert(newId)
        }

        // Rebuild nets. Internal pins are remapped to the pasted components;
        // external pins that are shared rails (VAC/ATM) still present in the
        // target document are kept as-is so the copy taps the same rail. Every
        // other external pin is dropped (a purely-internal wire becomes its own
        // isolated net; a signal net to an un-copied part isn't re-shorted).
        func isRail(_ id: UUID) -> Bool {
            switch document.circuit.logic.components.first(where: { $0.id == id })?.kind {
            case .vacuumSource, .atmVent: return true
            default: return false
            }
        }
        for pins in payload.nets {
            var combined: [PinRef] = []
            var externalRailPins: [PinRef] = []
            for pin in pins {
                if let newId = remap[pin.componentId] {
                    combined.append(PinRef(componentId: newId, pinKey: pin.pinKey))
                } else if isRail(pin.componentId) {
                    combined.append(pin)
                    externalRailPins.append(pin)
                }
            }
            guard combined.count >= 2 else { continue }
            // If the rail already has a net, join it (rails fan out to many
            // taps on one net); otherwise mint a fresh net for the group.
            if let idx = document.circuit.logic.nets.firstIndex(where: { net in
                externalRailPins.contains(where: { net.pins.contains($0) })
            }) {
                for pin in combined where !document.circuit.logic.nets[idx].pins.contains(pin) {
                    document.circuit.logic.nets[idx].pins.append(pin)
                }
            } else {
                document.circuit.logic.nets.append(
                    Net(label: document.circuit.logic.nextNetLabel(), pins: combined)
                )
            }
        }

        // Rebuild wire waypoints, offset to match the pasted positions.
        for entry in payload.waypoints {
            guard let na = remap[entry.pair.a.componentId],
                  let nb = remap[entry.pair.b.componentId] else { continue }
            let newA = PinRef(componentId: na, pinKey: entry.pair.a.pinKey)
            let newB = PinRef(componentId: nb, pinKey: entry.pair.b.pinKey)
            let points = entry.points.map {
                SchematicLayout.snapToGrid(Point(x: $0.x + delta, y: $0.y + delta))
            }
            document.circuit.schematic.setWaypoints(points, a: newA, b: newB)
        }
        // Drop any waypoint whose wire didn't survive the remap.
        document.circuit.schematic.pruneWaypoints(connectedIn: document.circuit.logic.nets)

        selection = SchematicSelection(components: pasted)
    }
}
