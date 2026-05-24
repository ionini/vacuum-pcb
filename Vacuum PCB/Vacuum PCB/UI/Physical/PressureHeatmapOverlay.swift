import SwiftUI

/// Sum-of-Gaussians pressure proxy over the board outline. Each screw drops a
/// Gaussian "bump" of unit amplitude at its shaft centre; the displayed field
/// is the per-cell sum, auto-normalised against the field's max so the heat
/// reads as uniformity (hot spots = many screws stacking, cold spots = gaps).
///
/// `sigma` (mm) is the Gaussian width — a stand-in for board + silicone
/// stiffness. Bigger σ = each screw's influence spreads further; smaller σ =
/// tight halos around each screw. Exposed as a user-driven slider since the
/// physically-correct value is design-dependent.
///
/// Rendered as a coloured grid of cells clipped to the board outline, below
/// the design layers so routes and placements stay readable on top.
struct PressureHeatmapOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    /// Gaussian width in mm. UI clamps to a sensible range; the overlay
    /// still self-protects against zero/negative input.
    let sigma: Double

    var body: some View {
        Canvas { ctx, _ in
            let outline = document.physical.boardOutline
            let centres = screwCentres()
            guard !centres.isEmpty else { return }
            let s = max(0.5, sigma)

            // Cell size aims for ~σ/4 mm so the gradient looks smooth, capped
            // at min/max counts so a tiny board doesn't degenerate and a huge
            // board doesn't blow the per-frame budget.
            let targetCellMm = max(0.5, s / 4)
            let cellsX = max(8, min(160, Int((outline.size.width  / targetCellMm).rounded(.up))))
            let cellsY = max(8, min(160, Int((outline.size.height / targetCellMm).rounded(.up))))
            let dx = outline.size.width  / Double(cellsX)
            let dy = outline.size.height / Double(cellsY)

            // Evaluate the field. Per cell, sum the Gaussian contribution from
            // every screw, skipping any beyond ~3.5σ where exp(-r²/2σ²) < 0.003
            // — a ~10× speedup on boards with many screws scattered widely.
            let twoSigmaSq = 2 * s * s
            let cutoff = 3.5 * s
            let cutoffSq = cutoff * cutoff
            var field = [Double](repeating: 0, count: cellsX * cellsY)
            for j in 0..<cellsY {
                let wy = outline.origin.y + (Double(j) + 0.5) * dy
                for i in 0..<cellsX {
                    let wx = outline.origin.x + (Double(i) + 0.5) * dx
                    var acc = 0.0
                    for c in centres {
                        let ex = wx - c.x
                        let ey = wy - c.y
                        if abs(ex) > cutoff || abs(ey) > cutoff { continue }
                        let r2 = ex * ex + ey * ey
                        if r2 > cutoffSq { continue }
                        acc += exp(-r2 / twoSigmaSq)
                    }
                    field[j * cellsX + i] = acc
                }
            }

            let maxVal = field.max() ?? 0
            guard maxVal > 0 else { return }

            // Translate each cell into screen-space and fill. Rects are drawn
            // edge-to-edge in world space; tiny 0.5 px overdraw avoids hairline
            // seams that show through when the canvas is zoomed in heavily.
            for j in 0..<cellsY {
                let wy0 = outline.origin.y + Double(j) * dy
                let wy1 = wy0 + dy
                for i in 0..<cellsX {
                    let v = field[j * cellsX + i] / maxVal
                    let wx0 = outline.origin.x + Double(i) * dx
                    let wx1 = wx0 + dx
                    let tl = transform.toScreen(Point(x: wx0, y: wy0))
                    let br = transform.toScreen(Point(x: wx1, y: wy1))
                    let rect = CGRect(
                        x: tl.x - 0.5, y: tl.y - 0.5,
                        width: (br.x - tl.x) + 1,
                        height: (br.y - tl.y) + 1
                    )
                    ctx.fill(Path(rect), with: .color(Self.heatColor(for: v).opacity(0.55)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    /// World-space centre of every screw placement. Screws are mechanical-only
    /// and live on `placements` keyed by a `.screw` component; the shaft sits
    /// at `placement.position` (the head / nut overhang are protrusions, not
    /// the pressure source — the user asked to model only the shaft).
    private func screwCentres() -> [Point] {
        var result: [Point] = []
        result.reserveCapacity(document.physical.placements.count)
        for placement in document.physical.placements {
            guard let comp = document.logic.components.first(where: { $0.id == placement.componentId }),
                  comp.kind == .screw
            else { continue }
            result.append(placement.position)
        }
        return result
    }

    /// Jet-style ramp: blue → cyan → green → yellow → red. Matches the user's
    /// mental model ("hot spots are red, gaps are blue").
    static func heatColor(for t: Double) -> Color {
        let v = max(0, min(1, t))
        let stops: [(Double, Double, Double, Double)] = [
            (0.00, 0.10, 0.30, 0.85),   // deep blue
            (0.25, 0.10, 0.75, 0.95),   // cyan
            (0.50, 0.20, 0.80, 0.30),   // green
            (0.75, 0.95, 0.85, 0.15),   // yellow
            (1.00, 0.90, 0.20, 0.15),   // red
        ]
        for i in 0..<(stops.count - 1) {
            let a = stops[i]
            let b = stops[i + 1]
            if v <= b.0 {
                let f = (v - a.0) / max(0.0001, b.0 - a.0)
                return Color(
                    red:   a.1 + (b.1 - a.1) * f,
                    green: a.2 + (b.2 - a.2) * f,
                    blue:  a.3 + (b.3 - a.3) * f
                )
            }
        }
        return Color(red: stops.last!.1, green: stops.last!.2, blue: stops.last!.3)
    }
}

/// Small legend strip + slider, designed to sit inside a popover hung off the
/// "Pressure" toolbar control. Kept as a separate view so the toolbar item
/// stays terse.
struct PressureHeatmapControls: View {
    @Binding var enabled: Bool
    @Binding var sigma: Double

    /// σ range (mm). Lower bound is "tight halo around each screw"; upper
    /// bound is "screw influence spans most of a typical board". The user can
    /// drag past either end of typical-board usefulness; we just keep them
    /// finite.
    static let sigmaRange: ClosedRange<Double> = 1...50

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Show pressure map", isOn: $enabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Spread (σ)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(sigma, specifier: "%.1f") mm")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $sigma, in: Self.sigmaRange)
                    .disabled(!enabled)
            }

            HStack(spacing: 4) {
                Text("low").font(.caption2).foregroundStyle(.tertiary)
                LinearGradient(
                    colors: stride(from: 0.0, through: 1.0, by: 0.05)
                        .map { PressureHeatmapOverlay.heatColor(for: $0) },
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(height: 8)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                Text("high").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 240)
    }
}
