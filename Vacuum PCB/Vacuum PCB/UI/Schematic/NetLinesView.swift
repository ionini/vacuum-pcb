import SwiftUI

/// Renders nets as a "rat's nest" — for each net with N pins, draw N-1 straight
/// lines from each non-anchor pin to the first pin. Not pretty; functional.
/// Selected nets stroke wider in the accent color so clicking the line is easy.
struct NetLinesView: View {
    let document: CircuitDocument
    let selection: SchematicSelection

    var body: some View {
        Canvas { ctx, _ in
            let positions = pinPositions()
            for net in document.logic.nets {
                guard let anchor = net.pins.first else { continue }
                guard let anchorPt = positions[anchor] else { continue }
                let isSelected = selection.netId == net.id
                for pin in net.pins.dropFirst() {
                    guard let pt = positions[pin] else { continue }
                    var path = Path()
                    path.move(to: anchorPt)
                    path.addLine(to: pt)
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
}
