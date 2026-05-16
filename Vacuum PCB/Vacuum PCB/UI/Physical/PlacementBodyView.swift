import SwiftUI

/// Renders one placement's physical footprint on the canvas — drawn directly
/// at the placement's world position, sized by the manufacturing constants.
/// Each component kind has its own glyph: dimple circle + s/d hole dots for the
/// transistor; serpentine outline for the resistor; arrow into the edge for ports.
struct PlacementBodyView: View {
    let component: Component
    let placement: Placement
    let manufacturing: ManufacturingConstants
    let transform: CanvasTransform
    let visible: LayerVisibility
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            Canvas { ctx, _ in
                let origin = transform.toScreen(placement.position)
                ctx.translateBy(x: origin.x, y: origin.y)
                ctx.rotate(by: .radians(placement.rotation.radians))

                switch component.kind {
                case .transistor:
                    drawTransistor(in: &ctx)
                case .resistor:
                    drawResistor(in: &ctx)
                case .vacuumSource, .atmVent, .port:
                    drawPort(in: &ctx)
                case .subpart:
                    // Subparts are rendered separately by SubpartExpandedView
                    // (dotted outline + transformed internals); the per-
                    // placement body view doesn't draw anything here.
                    break
                }

                if isSelected {
                    drawSelectionRing(in: &ctx)
                }
            }
            // Component label as a separate SwiftUI Text so it stays upright
            // regardless of placement rotation and uses crisp text rendering
            // rather than canvas-rasterised glyphs.
            label
        }
        .allowsHitTesting(false)
    }

    private var label: some View {
        let screen = transform.toScreen(placement.position)
        let offset = labelOffset()
        return Text(component.label)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .position(x: screen.x, y: screen.y + offset)
    }

    /// Pixels below the placement centre to drop the label. We use the *max*
    /// of width/height so rotation can't push the body into the label —
    /// rotating r90/r270 swaps width and height but the longer side has
    /// already been accounted for.
    private func labelOffset() -> CGFloat {
        let bounds = component.footprint(manufacturing).boundingRect
        let half = max(bounds.size.width, bounds.size.height) / 2
        return CGFloat(half) * transform.ptsPerMm + 10
    }

    // MARK: - Per-kind glyphs

    private func drawTransistor(in ctx: inout GraphicsContext) {
        let dimpleR = manufacturing.dimpleDiameter / 2 * transform.ptsPerMm
        let dimpleColor = plateColor(placement.layer)
        let dimpleRect = CGRect(x: -dimpleR, y: -dimpleR, width: 2 * dimpleR, height: 2 * dimpleR)
        ctx.fill(Path(ellipseIn: dimpleRect), with: .color(dimpleColor.opacity(0.25)))
        ctx.stroke(Path(ellipseIn: dimpleRect), with: .color(dimpleColor), lineWidth: 1.2)

        // Source/drain holes on the opposite plate
        let holeR = manufacturing.channelDiameter / 2 * transform.ptsPerMm
        let pitch = 1.5 * transform.ptsPerMm           // matches Footprint's halfPitch
        let holeColor = plateColor(placement.layer.opposite)
        for x in [-pitch, pitch] {
            let r = CGRect(x: x - holeR, y: -holeR, width: 2 * holeR, height: 2 * holeR)
            ctx.fill(Path(ellipseIn: r), with: .color(holeColor.opacity(0.45)))
            ctx.stroke(Path(ellipseIn: r), with: .color(holeColor), lineWidth: 1.0)
        }
    }

    private func drawResistor(in ctx: inout GraphicsContext) {
        // Draw just the serpentine channel — same waypoints + stroke width
        // the CAD pipeline carves into the plate. The footprint exclusion
        // rect is still enforced by DRC/auto-router, it's just no longer
        // drawn as a fat outline that visually inflates the resistor and
        // makes wiring around it feel cramped.
        let halfLen = ManufacturingConstants.resistorFootprintLength / 2
        let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
        // Resistors are pure tubes, so their drawn colour reflects the full
        // layer (plate + depth) the user has flipped them to — not just the
        // plate. That way a resistor flipped to T1 visually matches the T1
        // routes that will land on it.
        let color = LayerPalette.color(for: Layer(plate: placement.layer, depth: placement.depth))
        let transitions = ResistorGeometry.transitions(for: component.resistorSize ?? .medium)
        let waypoints = ResistorGeometry.path(
            transitions: transitions, halfLen: halfLen, halfWid: halfWid
        )
        guard let first = waypoints.first else { return }
        var path = Path()
        path.move(to: screen(first))
        for p in waypoints.dropFirst() { path.addLine(to: screen(p)) }
        ctx.stroke(
            path,
            with: .color(color.opacity(0.85)),
            style: StrokeStyle(
                lineWidth: max(1.2, manufacturing.resistorChannelDiameter * transform.ptsPerMm * 0.85),
                lineCap: .round,
                lineJoin: .round
            )
        )
    }

    private func screen(_ p: Point) -> CGPoint {
        CGPoint(x: p.x * transform.ptsPerMm, y: p.y * transform.ptsPerMm)
    }

    private func drawPort(in ctx: inout GraphicsContext) {
        // A triangle pointing in the +X direction (port exits through the +X edge
        // at rotation r0; the placement's rotation already rotates the canvas).
        let r = manufacturing.portBoreDiameter * transform.ptsPerMm
        var tri = Path()
        tri.move(to: CGPoint(x: r * 1.2, y: 0))
        tri.addLine(to: CGPoint(x: -r * 0.5, y:  r * 0.7))
        tri.addLine(to: CGPoint(x: -r * 0.5, y: -r * 0.7))
        tri.closeSubpath()
        let color = plateColor(placement.layer)
        ctx.fill(tri, with: .color(color.opacity(0.30)))
        ctx.stroke(tri, with: .color(color), lineWidth: 1.0)

        // A small dot at the pin (channel-side) end.
        let dotR = manufacturing.channelDiameter / 2 * transform.ptsPerMm
        let dotRect = CGRect(x: -dotR, y: -dotR, width: 2 * dotR, height: 2 * dotR)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
    }

    private func drawSelectionRing(in ctx: inout GraphicsContext) {
        let r = max(manufacturing.dimpleDiameter,
                    manufacturing.channelDiameter * 4) * transform.ptsPerMm
        let rect = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
        ctx.stroke(Path(ellipseIn: rect),
                   with: .color(.accentColor),
                   style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }

    /// Component features all live at the silicone-facing surface of their
    /// plate (depth 0), so reuse the shared depth-0 palette colour for that
    /// plate. Multi-layer depth tinting only applies to routes.
    private func plateColor(_ plate: Plate) -> Color {
        LayerPalette.color(for: Layer(plate: plate, depth: 0))
    }
}
