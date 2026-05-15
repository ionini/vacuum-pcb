import SwiftUI

/// Dashed "still to route" hint lines, one per pending connection in the
/// document's ratsnest. Drawn above the routes overlay (so they remain
/// visible against a busy board) but below pin handles (so they don't
/// intercept clicks on pins). Hidden via the bottom-strip toggle.
struct RatsnestOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform

    var body: some View {
        Canvas { ctx, _ in
            for edge in Ratsnest.missingEdges(document) {
                let a = transform.toScreen(edge.a)
                let b = transform.toScreen(edge.b)
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(
                    path,
                    with: .color(.orange.opacity(0.85)),
                    style: StrokeStyle(lineWidth: 1.2, dash: [5, 4])
                )
            }
        }
        .allowsHitTesting(false)
    }
}
