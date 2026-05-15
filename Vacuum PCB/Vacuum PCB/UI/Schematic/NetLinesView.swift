import SwiftUI

/// Renders nets as one line per edge in a hybrid layout: nets that have a
/// natural endpoint (a port or a rail) get drawn as a star anchored on that
/// pin; nets that connect only components fall back to a minimum spanning
/// tree on pin positions. So a net like (Q2.b, R3.1, Q6.b) with no port
/// shows Q2—R3—Q6, with each pin connected to its nearest neighbour in the
/// tree, instead of every pin spoking from whichever happened to be first.
///
/// Selected nets stroke wider in the accent color.
struct NetLinesView: View {
    let document: CircuitDocument
    let selection: SchematicSelection

    var body: some View {
        Canvas { ctx, _ in
            for net in document.logic.nets {
                let isSelected = selection.netId == net.id
                for edge in NetEdgeBuilder.edges(for: net, in: document) {
                    var path = Path()
                    path.move(to: edge.a.point)
                    path.addLine(to: edge.b.point)
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
}
