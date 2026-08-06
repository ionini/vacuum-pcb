import SwiftUI

/// Persistent wall-violation badges on the physical canvas: one diamond per
/// wall / clearance finding, red for errors, orange for warnings, planted at
/// the narrowest point of the offending gap. Zoomed in past a few pts/mm the
/// badge grows a chip with the measured wall ("0.32 mm"), so the user can
/// read the violation without visiting the sidebar.
///
/// Owns its own issue cache — recomputed on circuit changes with a short
/// debounce, mirroring `DRCSummarySection`, so drag ticks don't run a full
/// DRC pass per frame and panning/zooming (transform-only changes) never
/// recomputes at all.
struct DRCMarkersOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    let visible: LayerVisibility

    @State private var markers: [DRC.CanvasMarker] = []
    @State private var recompute: Task<Void, Never>?

    var body: some View {
        Canvas { ctx, _ in
            for marker in markers where isVisible(marker) {
                draw(marker, in: &ctx)
            }
        }
        .allowsHitTesting(false)
        .onAppear { markers = DRC.canvasMarkers(for: DRC.check(document), in: document) }
        .onChange(of: document) { _, doc in
            recompute?.cancel()
            recompute = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                markers = DRC.canvasMarkers(for: DRC.check(doc), in: doc)
            }
        }
    }

    /// Sheet mode shows only stencil findings (their geometry lives on the
    /// silicone sheet); channel modes follow the per-layer filter, same as
    /// the focus ping.
    private func isVisible(_ marker: DRC.CanvasMarker) -> Bool {
        if visible.isSiliconeSheet { return marker.onStencil }
        return !marker.onStencil && visible.contains(marker.layer)
    }

    private func draw(_ marker: DRC.CanvasMarker, in ctx: inout GraphicsContext) {
        let center = transform.toScreen(marker.position)
        let color: Color = marker.severity == .error ? .red : .orange

        // Soft halo so the badge reads even over a same-hue route.
        let haloR: CGFloat = 11
        ctx.fill(
            Path(ellipseIn: CGRect(x: center.x - haloR, y: center.y - haloR,
                                   width: haloR * 2, height: haloR * 2)),
            with: .color(color.opacity(0.18))
        )

        // Solid diamond with a white rim — distinct from the round via and
        // testing-point glyphs already on the canvas.
        let r: CGFloat = 6
        var diamond = Path()
        diamond.move(to: CGPoint(x: center.x, y: center.y - r))
        diamond.addLine(to: CGPoint(x: center.x + r, y: center.y))
        diamond.addLine(to: CGPoint(x: center.x, y: center.y + r))
        diamond.addLine(to: CGPoint(x: center.x - r, y: center.y))
        diamond.closeSubpath()
        ctx.fill(diamond, with: .color(color))
        ctx.stroke(diamond, with: .color(.white), lineWidth: 1.3)

        // Measurement chip, once there's room for it on screen.
        guard transform.ptsPerMm > 2.5, let label = marker.label else { return }
        let text = ctx.resolve(
            Text(label)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.white)
        )
        let size = text.measure(in: CGSize(width: 200, height: 40))
        let pad: CGFloat = 3
        let chip = CGRect(
            x: center.x + r + 4,
            y: center.y - size.height / 2 - pad,
            width: size.width + pad * 2,
            height: size.height + pad * 2
        )
        ctx.fill(Path(roundedRect: chip, cornerRadius: 4), with: .color(color.opacity(0.9)))
        ctx.draw(text, at: CGPoint(x: chip.midX, y: chip.midY), anchor: .center)
    }
}
