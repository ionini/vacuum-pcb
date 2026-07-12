import SwiftUI

/// Renders all routes on the physical canvas as Manhattan polylines colored by
/// layer. Selected segments draw wider in the accent color. Layer visibility is
/// applied: segments on a hidden layer are omitted.
struct RoutesOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    let visible: LayerVisibility
    /// Bottom-to-top layer paint order from the visibility pills. Segments
    /// are drawn grouped by this order so the layer dragged to the end of
    /// the row stacks on top of the others.
    let layerOrder: [Layer]
    let selection: PhysicalSelection
    let manufacturing: ManufacturingConstants
    /// In-progress vertex drag on the selected segment. When set, this segment
    /// renders using `dragOverride.waypoints` instead of the document's stored
    /// waypoints, so the polyline previews live as the user drags a handle.
    var dragOverride: DragOverride?
    /// In-progress placement drag with Cmd held: every waypoint listed in
    /// `attached` is rendered with `delta` added to its stored position, so
    /// the connected routes rubber-band along with the placement.
    var placementOverride: PlacementRouteOverride?

    struct DragOverride: Equatable {
        let netId: UUID
        let segmentIndex: Int
        let waypoints: [Point]
    }

    struct PlacementRouteOverride: Equatable {
        let delta: Point
        let attached: Set<RouteWaypointAddress>
    }
}

/// Stable identity for a single waypoint inside the document: which net, which
/// segment within that net's route, which waypoint within that segment. Used
/// to drive partial overrides in route rendering (placement drag rubber-band)
/// without copying full waypoint lists around.
///
/// `nonisolated` because the project's default actor isolation is `MainActor`
/// (see `SWIFT_DEFAULT_ACTOR_ISOLATION`). This is a pure value type stored in
/// `Set<RouteWaypointAddress>` and looked up via Hashable from contexts that
/// may not be on the main actor — without the marker, Swift 6 mode rejects
/// the conformance.
nonisolated struct RouteWaypointAddress: Hashable, Sendable {
    let netId: UUID
    let segmentIndex: Int
    let waypointIndex: Int
}

extension RoutesOverlay {

    var body: some View {
        Canvas { ctx, _ in
            let channelStroke = max(1.5, manufacturing.channelDiameter * transform.ptsPerMm * 0.85)
            // When a route segment is selected, every other segment on the
            // same net renders a translucent accent-coloured halo below the
            // normal stroke so the user can see the whole net as one shape —
            // useful for catching stranded segments and confirming routing
            // is actually complete.
            let highlightedNetId: UUID? = selection.routeSegment?.netId
            if let netId = highlightedNetId {
                for route in document.physical.routes where route.netId == netId {
                    for (segIdx, segment) in route.segments.enumerated() {
                        guard visible.contains(segment.layer) else { continue }
                        // Skip the selected segment itself — its existing
                        // accent-coloured wider stroke is already the visual
                        // anchor; stacking a halo on top adds nothing.
                        if selectionMatches(netId: route.netId, segmentIndex: segIdx) { continue }
                        let positions = waypoints(
                            for: route.netId, segmentIndex: segIdx,
                            fallback: segment.waypoints.map(\.position)
                        )
                        let pts = positions.map { transform.toScreen($0) }
                        guard pts.count >= 2 else { continue }
                        var path = Path()
                        path.move(to: pts[0])
                        for p in pts.dropFirst() { path.addLine(to: p) }
                        ctx.stroke(
                            path,
                            with: .color(Color.accentColor.opacity(0.35)),
                            style: StrokeStyle(
                                lineWidth: channelStroke + 5,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                    }
                }
            }

            // Main pass, drawn in layer paint order so a layer the user
            // dragged to the end of the pills stacks on top of the rest.
            for entry in orderedSegments() {
                let isSelected = selectionMatches(netId: entry.netId, segmentIndex: entry.segIdx)
                let positions = waypoints(
                    for: entry.netId, segmentIndex: entry.segIdx,
                    fallback: entry.segment.waypoints.map(\.position)
                )
                let pts = positions.map { transform.toScreen($0) }
                guard pts.count >= 2 else { continue }
                var path = Path()
                path.move(to: pts[0])
                for p in pts.dropFirst() { path.addLine(to: p) }

                let color: Color = isSelected ? .accentColor : layerColor(entry.segment.layer)
                ctx.stroke(
                    path,
                    with: .color(color.opacity(isSelected ? 0.9 : 0.55)),
                    style: StrokeStyle(
                        lineWidth: isSelected ? channelStroke + 2 : channelStroke,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// Every visible segment, ordered by its layer's paint rank (lower first
    /// = underneath). Ties preserve the document encounter order via `seq`
    /// so within-layer stacking stays deterministic. Layers missing from
    /// `layerOrder` rank last, so they paint on top rather than vanishing.
    private func orderedSegments() -> [(netId: UUID, segIdx: Int, segment: Segment)] {
        var rows: [(netId: UUID, segIdx: Int, segment: Segment, rank: Int, seq: Int)] = []
        var seq = 0
        for route in document.physical.routes {
            for (segIdx, segment) in route.segments.enumerated() {
                guard visible.contains(segment.layer) else { continue }
                let rank = layerOrder.firstIndex(of: segment.layer) ?? layerOrder.count
                rows.append((route.netId, segIdx, segment, rank, seq))
                seq += 1
            }
        }
        rows.sort { $0.rank != $1.rank ? $0.rank < $1.rank : $0.seq < $1.seq }
        return rows.map { ($0.netId, $0.segIdx, $0.segment) }
    }

    private func waypoints(for netId: UUID, segmentIndex: Int, fallback: [Point]) -> [Point] {
        // Vertex-drag override wins outright; it provides a full polyline.
        if let o = dragOverride, o.netId == netId, o.segmentIndex == segmentIndex {
            return o.waypoints
        }
        // Otherwise, optionally offset individual waypoints flagged by the
        // active placement drag (rubber-band).
        guard let p = placementOverride, !p.attached.isEmpty else { return fallback }
        return fallback.enumerated().map { i, point in
            let key = RouteWaypointAddress(netId: netId, segmentIndex: segmentIndex, waypointIndex: i)
            return p.attached.contains(key)
                ? Point(x: point.x + p.delta.x, y: point.y + p.delta.y)
                : point
        }
    }

    private func selectionMatches(netId: UUID, segmentIndex: Int) -> Bool {
        guard let s = selection.routeSegment else { return false }
        return s.netId == netId && s.segmentIndex == segmentIndex
    }

    private func layerColor(_ layer: Layer) -> Color {
        LayerPalette.color(for: layer)
    }
}

/// Shared layer → Color mapping. Plate sets the hue family (top = blue,
/// bottom = red) so the two plates remain instantly distinguishable; depth
/// rotates the hue slightly so additional channel layers on the same plate
/// read as distinct colours without leaving their family.
enum LayerPalette {
    static func color(for layer: Layer) -> Color {
        let palette: [Color] = layer.plate == .top
            ? [.blue, .cyan, .indigo]
            : [.red, .orange, .pink]
        return palette[min(layer.depth, palette.count - 1)]
    }
}

/// Renders vias as a concentric "target" symbol at every via waypoint XY
/// (deduped across the segment pair that share the position). Drawn on top of
/// the route polylines so the cross-layer transition reads clearly.
struct ViasOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    let visible: LayerVisibility
    let manufacturing: ManufacturingConstants

    var body: some View {
        Canvas { ctx, _ in
            // Show vias whenever either of their two segments would be
            // visible — same logic as the routes overlay.
            var seen: [Point] = []
            let outerRadius = max(5, manufacturing.channelDiameter * transform.ptsPerMm * 0.75)
            let innerRadius = outerRadius * 0.5
            // Vias that pierce the silicone (a T0↔B0 transition) are the
            // structurally significant ones, so they keep the full "target"
            // symbol — outer ring around the dot. Same-plate vias (e.g. T0→T1)
            // stay within one stack and read as a quieter plain dot, no ring.
            let crossSilicone = document.physical.crossSiliconeViaPositions()
            func crossesSilicone(_ p: Point) -> Bool {
                crossSilicone.contains {
                    abs($0.x - p.x) < 0.05 && abs($0.y - p.y) < 0.05
                }
            }
            for route in document.physical.routes {
                for segment in route.segments {
                    guard visible.contains(segment.layer) else { continue }
                    for wp in segment.waypoints where wp.kind == .via {
                        if seen.contains(where: {
                            abs($0.x - wp.position.x) < 0.05 && abs($0.y - wp.position.y) < 0.05
                        }) { continue }
                        seen.append(wp.position)
                        let center = transform.toScreen(wp.position)
                        let inner = CGRect(
                            x: center.x - innerRadius, y: center.y - innerRadius,
                            width: innerRadius * 2, height: innerRadius * 2
                        )
                        if crossesSilicone(wp.position) {
                            let outer = CGRect(
                                x: center.x - outerRadius, y: center.y - outerRadius,
                                width: outerRadius * 2, height: outerRadius * 2
                            )
                            ctx.fill(Path(ellipseIn: outer), with: .color(Color.primary.opacity(0.18)))
                            ctx.stroke(Path(ellipseIn: outer),
                                       with: .color(Color.primary.opacity(0.85)), lineWidth: 1.5)
                            ctx.fill(Path(ellipseIn: inner), with: .color(Color.primary.opacity(0.85)))
                        } else {
                            // Same-plate via: quiet dot, no surrounding ring.
                            ctx.fill(Path(ellipseIn: inner), with: .color(Color.primary.opacity(0.55)))
                        }
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Renders only the vias that punch through the silicone sheet — the
/// (T0, B0) pairs created by the "V" key. Same-plate vias (a route stepping
/// between depths on one plate) never touch the sheet and are skipped.
///
/// A via XY is considered cross-silicone when the same net has a `.via`
/// waypoint at that XY on a T0 segment *and* on a B0 segment. Approximate
/// matching (0.05 mm) mirrors the tolerance used elsewhere for paired-via
/// bookkeeping.
struct SiliconeSheetViasOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    let manufacturing: ManufacturingConstants

    var body: some View {
        Canvas { ctx, _ in
            // The cut hole equals the stencil cutter: channel diameter plus the
            // via-hole padding that compensates for silicone shrink. Drawing it
            // here keeps the Sheet view 1:1 with the exported stencil.
            let holeDiameter = manufacturing.channelDiameter + manufacturing.stencilViaPadding
            let radius = max(4, holeDiameter / 2 * transform.ptsPerMm)
            for position in document.physical.crossSiliconeViaPositions() {
                let center = transform.toScreen(position)
                let rect = CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )
                ctx.stroke(
                    Path(ellipseIn: rect),
                    with: .color(Color.primary.opacity(0.85)),
                    lineWidth: 1.5
                )
            }
        }
        .allowsHitTesting(false)
    }

}

/// Overlay showing the in-progress polyline while the user is routing.
/// Drawn as a dashed line; previews the auto-elbow that will be inserted on
/// next click — or, when `directRoute` is set (Cmd held), the straight run
/// that will be committed instead.
struct RoutingPreviewOverlay: View {
    let routingState: RoutingState
    let mouseLocation: CGPoint
    let transform: CanvasTransform
    let gridMm: Double
    /// Cmd held: preview a straight diagonal to the cursor, no corner.
    let directRoute: Bool

    var body: some View {
        Canvas { ctx, _ in
            guard case let .routing(_, waypoints, layer, _) = routingState,
                  let lastWorld = waypoints.last else { return }
            let mouseWorld = transform.snap(transform.toWorld(mouseLocation), grid: gridMm)

            let a = transform.toScreen(lastWorld)
            let c = transform.toScreen(mouseWorld)
            var path = Path()
            path.move(to: a)
            if !directRoute {
                let elbow = elbowPoint(from: lastWorld, to: mouseWorld)
                path.addLine(to: transform.toScreen(elbow))
            }
            path.addLine(to: c)
            ctx.stroke(
                path,
                with: .color(routeColor(layer)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [5, 3])
            )

            // Already-committed in-progress waypoints
            let committed = waypoints.map(transform.toScreen)
            if committed.count >= 2 {
                var committedPath = Path()
                committedPath.move(to: committed[0])
                for p in committed.dropFirst() { committedPath.addLine(to: p) }
                ctx.stroke(committedPath,
                           with: .color(routeColor(layer).opacity(0.9)),
                           style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
            }

            // Route head: a filled dot on the last committed waypoint so the
            // user can see exactly where the next tap extends from. Touch
            // has no live cursor between taps, so this is the only anchor
            // the eye gets — it's also where the HUD's chips drop a via.
            let headR: CGFloat = 4.5
            let headRect = CGRect(x: a.x - headR, y: a.y - headR,
                                  width: headR * 2, height: headR * 2)
            ctx.fill(Path(ellipseIn: headRect), with: .color(routeColor(layer)))
            ctx.stroke(Path(ellipseIn: headRect), with: .color(.white), lineWidth: 1.2)
        }
        .allowsHitTesting(false)
    }

    /// Manhattan elbow from `a` to `b`: pick whichever axis to travel first by
    /// preferring the longer one (keeps the elbow visually away from the cursor).
    private func elbowPoint(from a: Point, to b: Point) -> Point {
        let dx = abs(b.x - a.x)
        let dy = abs(b.y - a.y)
        return dx >= dy ? Point(x: b.x, y: a.y) : Point(x: a.x, y: b.y)
    }

    private func routeColor(_ layer: Layer) -> Color {
        LayerPalette.color(for: layer)
    }
}
