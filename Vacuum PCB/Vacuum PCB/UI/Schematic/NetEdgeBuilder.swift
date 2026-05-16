import SwiftUI

/// One drawn edge between two pins of the same net. Endpoints carry their
/// `PinRef` alongside the screen point so right-click hit-testing can map
/// from a clicked line back to "which pin should I remove?".
struct NetEdge {
    struct End {
        let pin: PinRef
        let point: CGPoint
    }
    let a: End
    let b: End
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
        let positions = pinPositions(in: document)
        let placed: [NetEdge.End] = net.pins.compactMap { ref in
            positions[ref].map { NetEdge.End(pin: ref, point: $0) }
        }
        guard placed.count >= 2 else { return [] }
        if let anchorIdx = explicitAnchor(in: placed, document: document) {
            return star(from: anchorIdx, pins: placed)
        }
        return mst(placed)
    }

    /// Resolves world-screen positions of every pin in the schematic.
    static func pinPositions(in document: CircuitDocument) -> [PinRef: CGPoint] {
        var out: [PinRef: CGPoint] = [:]
        for component in document.logic.components {
            guard let center = document.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics.metrics(for: component)
            for key in component.pinKeys {
                let off = metrics.pinOffset(key)
                out[PinRef(componentId: component.id, pinKey: key)] =
                    CGPoint(x: center.x + off.x, y: center.y + off.y)
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
