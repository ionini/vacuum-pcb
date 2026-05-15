import SwiftUI

/// Renders all routes on the physical canvas as Manhattan polylines colored by
/// layer. Selected segments draw wider in the accent color. Layer visibility is
/// applied: segments on a hidden layer are omitted.
struct RoutesOverlay: View {
    let document: CircuitDocument
    let transform: CanvasTransform
    let visible: LayerVisibility
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
            for route in document.physical.routes {
                for (segIdx, segment) in route.segments.enumerated() {
                    guard visible.contains(segment.layer) else { continue }
                    let isSelected = selectionMatches(netId: route.netId, segmentIndex: segIdx)
                    let positions = waypoints(
                        for: route.netId, segmentIndex: segIdx,
                        fallback: segment.waypoints.map(\.position)
                    )
                    let pts = positions.map { transform.toScreen($0) }
                    guard pts.count >= 2 else { continue }
                    var path = Path()
                    path.move(to: pts[0])
                    for p in pts.dropFirst() { path.addLine(to: p) }

                    let color: Color = isSelected ? .accentColor : layerColor(segment.layer)
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
        }
        .allowsHitTesting(false)
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
            for route in document.physical.routes {
                for segment in route.segments {
                    guard visible.contains(segment.layer) else { continue }
                    for wp in segment.waypoints where wp.kind == .via {
                        if seen.contains(where: {
                            abs($0.x - wp.position.x) < 0.05 && abs($0.y - wp.position.y) < 0.05
                        }) { continue }
                        seen.append(wp.position)
                        let center = transform.toScreen(wp.position)
                        let outer = CGRect(
                            x: center.x - outerRadius, y: center.y - outerRadius,
                            width: outerRadius * 2, height: outerRadius * 2
                        )
                        let inner = CGRect(
                            x: center.x - innerRadius, y: center.y - innerRadius,
                            width: innerRadius * 2, height: innerRadius * 2
                        )
                        ctx.fill(Path(ellipseIn: outer), with: .color(Color.primary.opacity(0.18)))
                        ctx.stroke(Path(ellipseIn: outer),
                                   with: .color(Color.primary.opacity(0.85)), lineWidth: 1.5)
                        ctx.fill(Path(ellipseIn: inner), with: .color(Color.primary.opacity(0.85)))
                    }
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// Overlay showing the in-progress polyline while the user is routing.
/// Drawn as a dashed line; previews the auto-elbow that will be inserted on next click.
struct RoutingPreviewOverlay: View {
    let routingState: RoutingState
    let mouseLocation: CGPoint
    let transform: CanvasTransform
    let gridMm: Double

    var body: some View {
        Canvas { ctx, _ in
            guard case let .routing(_, waypoints, layer, _) = routingState,
                  let lastWorld = waypoints.last else { return }
            let mouseWorld = transform.snap(transform.toWorld(mouseLocation), grid: gridMm)
            let elbow = elbowPoint(from: lastWorld, to: mouseWorld)

            let a = transform.toScreen(lastWorld)
            let b = transform.toScreen(elbow)
            let c = transform.toScreen(mouseWorld)
            var path = Path()
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
            ctx.stroke(
                path,
                with: .color(routeColor(layer)),
                style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round, dash: [5, 3])
            )

            // Already-committed in-progress waypoints
            let committed = waypoints.map(transform.toScreen)
            guard committed.count >= 2 else { return }
            var committedPath = Path()
            committedPath.move(to: committed[0])
            for p in committed.dropFirst() { committedPath.addLine(to: p) }
            ctx.stroke(committedPath,
                       with: .color(routeColor(layer).opacity(0.9)),
                       style: StrokeStyle(lineWidth: 2.0, lineCap: .round, lineJoin: .round))
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
