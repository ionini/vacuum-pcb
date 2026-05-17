import SwiftUI

/// Renders an expanded sub-part instance on the physical canvas:
///   * dotted outline (the library file's `boardOutline` transformed by the
///     instance pose) with a `label — partName` title above it
///   * every internal placement at its transformed pose, using the same
///     glyphs primitives use (read-only — these aren't selectable in v1)
///   * every internal route polyline, layer-coloured exactly like parent
///     routes
///   * generic labeled dot for each boundary pin so the user has a snap
///     target to wire to from the parent side
///
/// Pin handles for routing INTO the instance are drawn by `PhysicalCanvasView`
/// just like any other placement — `Component.subpartFootprint()` exposes the
/// boundary pins in parent-local coordinates so the existing pin-handle
/// machinery handles snap, click-to-start-route, and ratsnest.
struct SubpartExpandedView: View {
    let component: Component
    let placement: Placement
    let parentManufacturing: ManufacturingConstants
    let transform: CanvasTransform
    let visible: LayerVisibility
    let isSelected: Bool
    /// Chain of library filenames already being expanded above this view.
    /// A nested subpart whose `partRef` is already in this set is rendered
    /// as a red cycle placeholder instead of recursing.
    var visiting: Set<String> = []

    var body: some View {
        if let filename = component.partRef, visiting.contains(filename) {
            cyclePlaceholder(filename: filename)
        } else if let part = component.partRef.flatMap({ PartsLibrary.shared.part(named: $0) }) {
            let part = part
            ZStack {
                // 1. Internal routes — drawn underneath placements so the
                // serpentines / glyphs sit on top.
                internalRoutes(part: part)
                // 2. Internal placements (transistors, resistors, etc.).
                internalPlacements(part: part)
                // 3. Boundary pin markers + labels.
                boundaryMarkers(part: part)
                // 4. Dotted outline + title sit on top so the part reads as a
                // visually grouped block.
                outline(part: part)
            }
        } else {
            // Missing-part placeholder: red dotted box at the instance
            // position, sized like a typical part so it's visible.
            missingPlaceholder
        }
    }

    // MARK: - Outline + title

    private func outline(part: PartsLibrary.Part) -> some View {
        let lib = part.document.physical.boardOutline
        let corners = boardCorners(lib).map { transformWorld($0) }
        return Canvas { ctx, _ in
            var path = Path()
            path.move(to: transform.toScreen(corners[0]))
            for c in corners.dropFirst() {
                path.addLine(to: transform.toScreen(c))
            }
            path.closeSubpath()
            ctx.stroke(
                path,
                with: .color(isSelected ? Color.accentColor : Color.teal.opacity(0.85)),
                style: StrokeStyle(
                    lineWidth: isSelected ? 2.0 : 1.4,
                    lineCap: .round, lineJoin: .round,
                    dash: [6, 4]
                )
            )
        }
        .allowsHitTesting(false)
        .overlay(alignment: .topLeading) {
            outlineTitle(part: part, topLeft: corners[0])
        }
    }

    @ViewBuilder
    private func outlineTitle(part: PartsLibrary.Part, topLeft: Point) -> some View {
        let screen = transform.toScreen(topLeft)
        Text("\(component.label) — \(part.displayName)")
            .font(.system(size: 11, weight: .semibold))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 3))
            .fixedSize()
            .position(x: screen.x + 4, y: screen.y - 8)
            .allowsHitTesting(false)
    }

    private var missingPlaceholder: some View {
        Canvas { ctx, _ in
            let half = 8.0
            let corners = [
                Point(x: placement.position.x - half, y: placement.position.y - half),
                Point(x: placement.position.x + half, y: placement.position.y - half),
                Point(x: placement.position.x + half, y: placement.position.y + half),
                Point(x: placement.position.x - half, y: placement.position.y + half),
            ]
            var path = Path()
            path.move(to: transform.toScreen(corners[0]))
            for c in corners.dropFirst() {
                path.addLine(to: transform.toScreen(c))
            }
            path.closeSubpath()
            ctx.stroke(
                path,
                with: .color(.red),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [4, 3])
            )
            let label = "Missing: \(component.partRef ?? "?")"
            ctx.draw(
                Text(label).font(.system(size: 10, weight: .semibold)).foregroundColor(.red),
                at: transform.toScreen(Point(x: placement.position.x, y: placement.position.y))
            )
        }
        .allowsHitTesting(false)
    }

    /// Cycle placeholder: visually mirrors the missing-part one but with a
    /// "Cycle: A → B → A" label so the user can trace where the loop closes.
    private func cyclePlaceholder(filename: String) -> some View {
        let chain = (Array(visiting) + [filename]).joined(separator: " → ")
        return Canvas { ctx, _ in
            let half = 8.0
            let corners = [
                Point(x: placement.position.x - half, y: placement.position.y - half),
                Point(x: placement.position.x + half, y: placement.position.y - half),
                Point(x: placement.position.x + half, y: placement.position.y + half),
                Point(x: placement.position.x - half, y: placement.position.y + half),
            ]
            var path = Path()
            path.move(to: transform.toScreen(corners[0]))
            for c in corners.dropFirst() {
                path.addLine(to: transform.toScreen(c))
            }
            path.closeSubpath()
            ctx.stroke(
                path,
                with: .color(.red),
                style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [4, 3])
            )
            ctx.draw(
                Text("Cycle: \(chain)").font(.system(size: 10, weight: .semibold)).foregroundColor(.red),
                at: transform.toScreen(Point(x: placement.position.x, y: placement.position.y))
            )
        }
        .allowsHitTesting(false)
    }

    // MARK: - Internal placements

    private func internalPlacements(part: PartsLibrary.Part) -> some View {
        // Visiting set passed down into any nested SubpartExpandedView so a
        // cycle (A.vpcb → B.vpcb → A.vpcb) renders as a placeholder instead
        // of recursing forever. Keyed by library filename, matching the
        // rule used by `CircuitDocument.flattened(visiting:)`.
        let childVisiting = component.partRef.map { visiting.union([$0]) } ?? visiting
        return ZStack {
            ForEach(part.document.physical.placements, id: \.componentId) { internalPlacement in
                if let internalComponent = part.document.logic.components.first(where: { $0.id == internalPlacement.componentId }),
                   // Boundary components are drawn as pin markers instead of
                   // their full glyph (per the v1 spec).
                   !isBoundaryComponent(internalComponent) {
                    let effective = effectivePlacement(of: internalPlacement)
                    if internalComponent.kind == .subpart {
                        // Nested subpart: recurse so the user sees the full
                        // hierarchy expanded (Half Adder → XOR → transistors).
                        SubpartExpandedView(
                            component: internalComponent,
                            placement: effective,
                            parentManufacturing: part.document.manufacturing,
                            transform: transform,
                            visible: visible,
                            isSelected: false,
                            visiting: childVisiting
                        )
                    } else if internalComponent.kind == .screw
                        || visible.contains(Layer(plate: effective.layer, depth: effective.depth)) {
                        // Screws live across both plates mechanically — same
                        // exemption from layer-filtering as primitive screws
                        // on the parent canvas.
                        PlacementBodyView(
                            component: internalComponent,
                            placement: effective,
                            manufacturing: part.document.manufacturing,
                            transform: transform,
                            visible: visible,
                            isSelected: false
                        )
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func isBoundaryComponent(_ component: Component) -> Bool {
        component.kind == .port
            || component.kind == .vacuumSource
            || component.kind == .atmVent
    }

    // MARK: - Internal routes

    private func internalRoutes(part: PartsLibrary.Part) -> some View {
        let channelStroke = max(
            1.5,
            part.document.manufacturing.channelDiameter * transform.ptsPerMm * 0.85
        )
        return Canvas { ctx, _ in
            for route in part.document.physical.routes {
                for segment in route.segments {
                    guard visible.contains(segment.layer) else { continue }
                    let pts = segment.waypoints.map { transformWorld($0.position) }
                    let screen = pts.map { transform.toScreen($0) }
                    guard screen.count >= 2 else { continue }
                    var path = Path()
                    path.move(to: screen[0])
                    for p in screen.dropFirst() { path.addLine(to: p) }
                    ctx.stroke(
                        path,
                        with: .color(LayerPalette.color(for: segment.layer).opacity(0.55)),
                        style: StrokeStyle(lineWidth: channelStroke, lineCap: .round, lineJoin: .round)
                    )
                    // Vias as a small target.
                    for wp in segment.waypoints where wp.kind == .via {
                        let center = transform.toScreen(transformWorld(wp.position))
                        let r: CGFloat = max(4, channelStroke * 0.55)
                        let rect = CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .color(Color.primary.opacity(0.85)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Boundary markers

    private func boundaryMarkers(part: PartsLibrary.Part) -> some View {
        ZStack {
            ForEach(part.pins, id: \.portId) { pin in
                // Hide pins on a hidden plate — same rule that filters
                // primitive port placements, so showing T0 alone leaves
                // only the top-plate boundary pins visible.
                if visible.contains(Layer(plate: pin.plate, depth: 0)) {
                    let world = transformWorld(pin.physicalAnchor)
                    let screen = transform.toScreen(world)
                    ZStack {
                        Circle()
                            .fill(LayerPalette.color(for: Layer(plate: pin.plate, depth: 0)).opacity(0.85))
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 0.5))
                        Text(pin.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 2)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 2))
                            .fixedSize()
                            .offset(labelOffset(for: pin.side))
                    }
                    .position(screen)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func labelOffset(for side: SymbolSide) -> CGSize {
        switch side {
        case .left:   return CGSize(width: -22, height: 0)
        case .right:  return CGSize(width: 22, height: 0)
        case .top:    return CGSize(width: 0, height: -14)
        case .bottom: return CGSize(width: 0, height: 14)
        }
    }

    // MARK: - Coordinate transforms

    /// Library boardOutline corners in library space (TL, TR, BR, BL).
    private func boardCorners(_ outline: Rect) -> [Point] {
        [
            Point(x: outline.minX, y: outline.minY),
            Point(x: outline.maxX, y: outline.minY),
            Point(x: outline.maxX, y: outline.maxY),
            Point(x: outline.minX, y: outline.maxY),
        ]
    }

    /// Maps a point in library-local mm coordinates into parent mm
    /// coordinates by translating so the library's `boardOutline` top-left
    /// corner sits at `placement.position`, then rotating about that corner
    /// by `placement.rotation`. Corner-anchored to match `subpartFootprint()`.
    private func transformWorld(_ libraryPoint: Point) -> Point {
        let outline = component.partRef
            .flatMap { PartsLibrary.shared.part(named: $0) }?
            .document.physical.boardOutline
            ?? Rect(origin: .zero, size: Size(width: 0, height: 0))
        let dx = libraryPoint.x - outline.minX
        let dy = libraryPoint.y - outline.minY
        let r = placement.rotation.radians
        let cosR = cos(r), sinR = sin(r)
        return Point(
            x: placement.position.x + dx * cosR - dy * sinR,
            y: placement.position.y + dx * sinR + dy * cosR
        )
    }

    /// Synthesizes a parent-space `Placement` for one internal placement so
    /// the existing `PlacementBodyView` can render it without modification.
    /// Composes rotations (internal + instance) and translates per the same
    /// rule as `transformWorld`.
    private func effectivePlacement(of internalPlacement: Placement) -> Placement {
        let world = transformWorld(internalPlacement.position)
        let composed = composeRotation(internalPlacement.rotation, then: placement.rotation)
        return Placement(
            componentId: internalPlacement.componentId,
            position: world,
            rotation: composed,
            layer: internalPlacement.layer,
            depth: internalPlacement.depth
        )
    }

    private func composeRotation(_ first: Rotation, then second: Rotation) -> Rotation {
        let order: [Rotation] = [.r0, .r90, .r180, .r270]
        let i = (order.firstIndex(of: first) ?? 0)
              + (order.firstIndex(of: second) ?? 0)
        return order[i % 4]
    }
}
