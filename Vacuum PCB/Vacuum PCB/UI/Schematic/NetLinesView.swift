import SwiftUI

/// Renders nets as a star from a "preferred anchor" pin: every other pin draws
/// one line to the anchor. Anchor picked by kind — port first (input/output),
/// then a rail (vacuum source / atm vent), then the first pin if neither
/// exists. This matches the mental model "everything connects to the port /
/// rail" better than KiCad's MST, which can hop between physically-close
/// component pins and obscure where a net actually terminates.
///
/// Selected nets stroke wider in the accent color.
struct NetLinesView: View {
    let document: CircuitDocument
    let selection: SchematicSelection

    var body: some View {
        Canvas { ctx, _ in
            let positions = pinPositions()
            for net in document.logic.nets {
                let isSelected = selection.netId == net.id
                let placed = net.pins.compactMap { ref in positions[ref].map { (ref, $0) } }
                for (a, b) in starEdges(placed) {
                    var path = Path()
                    path.move(to: a)
                    path.addLine(to: b)
                    ctx.stroke(
                        path,
                        with: .color(isSelected ? .accentColor : .secondary),
                        lineWidth: isSelected ? 2.5 : 1.2
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// World screen positions of every pin on the schematic canvas.
    private func pinPositions() -> [PinRef: CGPoint] {
        var out: [PinRef: CGPoint] = [:]
        for component in document.logic.components {
            guard let center = document.schematic.position(for: component.id) else { continue }
            let metrics = ComponentSymbolMetrics.metrics(for: component.kind)
            for key in component.kind.pinKeys {
                let off = metrics.pinOffset(key)
                let ref = PinRef(componentId: component.id, pinKey: key)
                out[ref] = CGPoint(x: center.x + off.x, y: center.y + off.y)
            }
        }
        return out
    }

    /// Star: pick an anchor pin, draw a line from it to every other pin.
    private func starEdges(_ pins: [(PinRef, CGPoint)]) -> [(CGPoint, CGPoint)] {
        guard pins.count >= 2 else { return [] }
        let anchorIdx = preferredAnchor(in: pins)
        let anchor = pins[anchorIdx].1
        var edges: [(CGPoint, CGPoint)] = []
        edges.reserveCapacity(pins.count - 1)
        for (i, entry) in pins.enumerated() where i != anchorIdx {
            edges.append((anchor, entry.1))
        }
        return edges
    }

    /// Anchor priority: port (input/output) > rail (vac/vent) > first pin.
    /// Resolves once per net per redraw; nets are small (a handful of pins).
    private func preferredAnchor(in pins: [(PinRef, CGPoint)]) -> Int {
        func kind(of ref: PinRef) -> ComponentKind? {
            document.logic.components.first(where: { $0.id == ref.componentId })?.kind
        }
        if let i = pins.firstIndex(where: { kind(of: $0.0) == .port }) { return i }
        if let i = pins.firstIndex(where: {
            let k = kind(of: $0.0); return k == .vacuumSource || k == .atmVent
        }) { return i }
        return 0
    }
}
