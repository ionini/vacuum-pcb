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

                if visible.isSiliconeSheet {
                    drawSiliconeSheetGlyph(in: &ctx)
                } else {
                    switch component.kind {
                    case .transistor:
                        drawTransistor(in: &ctx)
                    case .resistor:
                        drawResistor(in: &ctx)
                    case .vacuumSource, .atmVent, .port:
                        drawPort(in: &ctx)
                    case .subpart:
                        // Subparts are rendered separately by
                        // SubpartExpandedView (dotted outline +
                        // transformed internals); the per-placement body
                        // view doesn't draw anything here.
                        break
                    case .screw:
                        drawScrew(in: &ctx)
                    case .led:
                        drawLED(in: &ctx)
                    }
                }

                if isSelected {
                    drawSelectionRing(in: &ctx)
                }
            }
            // Component label as a separate SwiftUI Text so it stays upright
            // regardless of placement rotation and uses crisp text rendering
            // rather than canvas-rasterised glyphs. Silicone-sheet mode is a
            // bare physical preview, so labels would just be noise — drop them.
            if !visible.isSiliconeSheet {
                label
            }
        }
        .allowsHitTesting(false)
    }

    /// Silicone-sheet mode: draw only the feature that punches through the
    /// silicone. Transistors → gate dimple circumference. LEDs → LED
    /// dimple circumference (same idea, different diameter). Screws → the
    /// 2.2 mm clearance bore (the actual hole through the sheet). All
    /// other kinds are filtered out upstream and never get this far.
    private func drawSiliconeSheetGlyph(in ctx: inout GraphicsContext) {
        let strokeColor = Color.primary.opacity(0.85)
        switch component.kind {
        case .transistor:
            let r = manufacturing.dimpleDiameter / 2 * transform.ptsPerMm
            let rect = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(strokeColor), lineWidth: 1.4)
        case .led:
            let r = manufacturing.ledDimpleDiameter / 2 * transform.ptsPerMm
            let rect = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(strokeColor), lineWidth: 1.4)
        case .screw:
            let r = ScrewGeometry.throughDiameter / 2 * transform.ptsPerMm
            let rect = CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r)
            ctx.stroke(Path(ellipseIn: rect), with: .color(strokeColor), lineWidth: 1.4)
        default:
            break
        }
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
        tri.addLine(to: CGPoint(x: -r * 0.5, y: r * 0.7))
        tri.addLine(to: CGPoint(x: -r * 0.5, y: -r * 0.7))
        tri.closeSubpath()
        // Match resistor behaviour: edge-bore ports/vents/vacuum sources can
        // sit on any channel layer, so colour by full layer (plate + depth).
        let color = LayerPalette.color(for: Layer(plate: placement.layer, depth: placement.depth))
        ctx.fill(tri, with: .color(color.opacity(0.30)))
        ctx.stroke(tri, with: .color(color), lineWidth: 1.0)

        // A small dot at the pin (channel-side) end.
        let dotR = manufacturing.channelDiameter / 2 * transform.ptsPerMm
        let dotRect = CGRect(x: -dotR, y: -dotR, width: 2 * dotR, height: 2 * dotR)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(color))
    }

    private func drawScrew(in ctx: inout GraphicsContext) {
        // Three concentric features matching the CAD cutters: outer ring =
        // head countersink (5.1 mm), middle dashed circle = clearance hole,
        // hex outline indicates the nut pocket orientation on the bottom.
        let headR = ScrewGeometry.headDiameter / 2 * transform.ptsPerMm
        let throughR = ScrewGeometry.throughDiameter / 2 * transform.ptsPerMm
        let hexCircumR = (ScrewGeometry.hexAcrossFlats / sqrt(3.0)) * transform.ptsPerMm

        let headRect = CGRect(x: -headR, y: -headR, width: 2 * headR, height: 2 * headR)
        ctx.fill(Path(ellipseIn: headRect), with: .color(Color.gray.opacity(0.18)))
        ctx.stroke(Path(ellipseIn: headRect), with: .color(.gray), lineWidth: 1.2)

        let throughRect = CGRect(x: -throughR, y: -throughR, width: 2 * throughR, height: 2 * throughR)
        ctx.fill(Path(ellipseIn: throughRect), with: .color(Color.primary.opacity(0.55)))
        ctx.stroke(Path(ellipseIn: throughRect), with: .color(Color.primary.opacity(0.7)), lineWidth: 0.8)

        // Hex outline: starts at 30° so two flats sit perpendicular to the
        // local X axis (same convention as the CAD prism).
        var hex = Path()
        for i in 0..<6 {
            let a = .pi / 6 + Double(i) * .pi / 3
            let x = hexCircumR * cos(a)
            let y = hexCircumR * sin(a)
            if i == 0 { hex.move(to: CGPoint(x: x, y: y)) } else { hex.addLine(to: CGPoint(x: x, y: y)) }
        }
        hex.closeSubpath()
        ctx.stroke(
            hex,
            with: .color(Color.primary.opacity(0.55)),
            style: StrokeStyle(lineWidth: 0.8, dash: [3, 2])
        )
    }

    private func drawLED(in ctx: inout GraphicsContext) {
        // Dimple on the placement layer + viewing-hole ring on the opposite
        // plate. Drawn from the inside out so the viewing-hole ring is on top.
        let dimpleR = manufacturing.ledDimpleDiameter / 2 * transform.ptsPerMm
        let dimpleColor = plateColor(placement.layer)
        let dimpleRect = CGRect(x: -dimpleR, y: -dimpleR, width: 2 * dimpleR, height: 2 * dimpleR)
        ctx.fill(Path(ellipseIn: dimpleRect), with: .color(dimpleColor.opacity(0.30)))
        ctx.stroke(Path(ellipseIn: dimpleRect), with: .color(dimpleColor), lineWidth: 1.2)

        // Viewing hole (opposite plate) — dashed ring 0.5 mm wider in radius.
        let viewR = (manufacturing.ledDimpleDiameter / 2 + 0.5) * transform.ptsPerMm
        let viewColor = plateColor(placement.layer.opposite)
        let viewRect = CGRect(x: -viewR, y: -viewR, width: 2 * viewR, height: 2 * viewR)
        ctx.stroke(
            Path(ellipseIn: viewRect),
            with: .color(viewColor),
            style: StrokeStyle(lineWidth: 1.0, dash: [4, 3])
        )

        // Pin dot at the centre.
        let dotR = manufacturing.channelDiameter / 2 * transform.ptsPerMm
        let dotRect = CGRect(x: -dotR, y: -dotR, width: 2 * dotR, height: 2 * dotR)
        ctx.fill(Path(ellipseIn: dotRect), with: .color(dimpleColor))
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
