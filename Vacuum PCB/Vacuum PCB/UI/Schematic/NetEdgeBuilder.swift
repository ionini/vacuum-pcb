import SwiftUI

/// One drawn edge between two pins of the same net. Endpoints carry their
/// `PinRef` alongside the screen point so right-click hit-testing can map
/// from a clicked line back to "which pin should I remove?".
struct NetEdge {
    struct End {
        let pin: PinRef
        let point: CGPoint
        /// Direction the wire leaves this pin (perpendicular to the symbol
        /// edge it sits on), used to route the edge orthogonally.
        let exit: ExitDir
    }
    let a: End
    let b: End

    /// Orthogonal polyline this edge renders as — each pin's stub plus the
    /// minimal-corner bridge between them. Shared by the editor renderer
    /// (`NetLinesView`), the Simulate canvas, and the right-click hit-test so
    /// all three agree on the wire's shape.
    func polyline(stub: CGFloat = 14) -> [CGPoint] {
        WireRouter.route(from: a.point, a.exit, to: b.point, b.exit, stub: stub)
    }

    /// The polyline with rounded corners, ready to stroke.
    func roundedPath(radius: CGFloat = 9, stub: CGFloat = 14) -> Path {
        WireRouter.roundedPath(polyline(stub: stub), radius: radius)
    }
}

/// Shared geometry of a net's rendered "rat's nest". Used both by
/// `NetLinesView` (to draw) and by `SchematicCanvasView` (to hit-test
/// right-click events for pin removal).
enum NetEdgeBuilder {

    /// Builds the edges to draw for a single net.
    ///
    /// Layout rule:
    ///   * If the net contains a port or a rail (vacuum / vent), draw a star
    ///     from that pin — every other pin gets a single line to the anchor.
    ///     Matches the mental model "everything terminates at the port."
    ///   * Otherwise (component-only net) compute a minimum spanning tree on
    ///     pin positions, so adjacent components are connected to their
    ///     nearest neighbour in the tree rather than all spoking from the
    ///     first-added pin.
    static func edges(for net: Net, in document: CircuitDocument) -> [NetEdge] {
        edges(for: net, in: document, geometry: pinGeometry(in: document))
    }

    /// Variant that reuses a precomputed pin-geometry map. Callers that build
    /// edges for many nets at once (the hover hit-test, the renderer) compute
    /// `pinGeometry` once and pass it here rather than rebuilding it per net.
    static func edges(for net: Net, in document: CircuitDocument,
                      geometry: [PinRef: PinGeometry]) -> [NetEdge] {
        let placed: [NetEdge.End] = net.pins.compactMap { ref in
            geometry[ref].map { NetEdge.End(pin: ref, point: $0.point, exit: $0.exit) }
        }
        guard placed.count >= 2 else { return [] }
        if let anchorIdx = explicitAnchor(in: placed, document: document) {
            return star(from: anchorIdx, pins: placed)
        }
        return mst(placed)
    }

    /// World position + exit direction of a pin, with the owning component's
    /// schematic rotation already baked in.
    struct PinGeometry {
        let point: CGPoint
        let exit: ExitDir
    }

    /// Resolves the world-screen position and exit direction of every pin in
    /// the schematic, applying each component's schematic rotation. The single
    /// source of truth for "where is this pin and which way does its wire
    /// leave" — used for routing, hit-testing, and the rubber-band line.
    static func pinGeometry(in document: CircuitDocument) -> [PinRef: PinGeometry] {
        var out: [PinRef: PinGeometry] = [:]
        for component in document.logic.components {
            guard let center = document.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics
                .metrics(for: component, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: component.id))
            for key in component.pinKeys(snapshots: document.librarySnapshots) {
                let off = metrics.pinOffset(key)
                out[PinRef(componentId: component.id, pinKey: key)] = PinGeometry(
                    point: CGPoint(x: center.x + off.x, y: center.y + off.y),
                    exit: ExitDir.from(off)
                )
            }
        }
        return out
    }

    // MARK: - Layout strategies

    private static func explicitAnchor(in pins: [NetEdge.End], document: CircuitDocument) -> Int? {
        func kind(of ref: PinRef) -> ComponentKind? {
            document.logic.components.first(where: { $0.id == ref.componentId })?.kind
        }
        if let i = pins.firstIndex(where: { kind(of: $0.pin) == .port }) { return i }
        if let i = pins.firstIndex(where: {
            let k = kind(of: $0.pin); return k == .vacuumSource || k == .atmVent
        }) { return i }
        return nil
    }

    private static func star(from anchorIdx: Int, pins: [NetEdge.End]) -> [NetEdge] {
        let anchor = pins[anchorIdx]
        var edges: [NetEdge] = []
        edges.reserveCapacity(pins.count - 1)
        for (i, end) in pins.enumerated() where i != anchorIdx {
            edges.append(NetEdge(a: anchor, b: end))
        }
        return edges
    }

    /// Kruskal's: sort all pair distances, accept the shortest edge that
    /// joins two previously-disconnected components. N is small (handful
    /// of pins per net), so O(N² log N) is fine.
    private static func mst(_ pins: [NetEdge.End]) -> [NetEdge] {
        guard pins.count >= 2 else { return [] }
        var pairs: [(i: Int, j: Int, d: Double)] = []
        pairs.reserveCapacity(pins.count * (pins.count - 1) / 2)
        for i in 0..<pins.count {
            for j in (i + 1)..<pins.count {
                let dx = pins[i].point.x - pins[j].point.x
                let dy = pins[i].point.y - pins[j].point.y
                pairs.append((i, j, Double(dx * dx + dy * dy)))
            }
        }
        pairs.sort { $0.d < $1.d }

        var parent = Array(0..<pins.count)
        func find(_ x: Int) -> Int {
            var c = x
            while parent[c] != c {
                parent[c] = parent[parent[c]]
                c = parent[c]
            }
            return c
        }

        var edges: [NetEdge] = []
        edges.reserveCapacity(pins.count - 1)
        for pair in pairs {
            let ri = find(pair.i), rj = find(pair.j)
            if ri != rj {
                parent[ri] = rj
                edges.append(NetEdge(a: pins[pair.i], b: pins[pair.j]))
                if edges.count == pins.count - 1 { break }
            }
        }
        return edges
    }
}
