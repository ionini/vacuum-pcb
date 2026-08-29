import SwiftUI

/// Falstad-style mass-flow animation for the Simulate physical view: marching
/// dots along every path air is moving through, dot speed ∝ √(|Q| / pump
/// ceiling), direction = the actual flow direction. A pull-up quietly holding
/// an isolated node shows only the slow leak crawl; one fighting an open vent
/// path lights up as a continuous stream from the vent through the transistor
/// and pull-up into the rail — the static draw that starves the supply, made
/// visible.
///
/// Three kinds of path:
///   * channel spans (geometry retained by `ChannelGraph`) — exact per-span
///     flows, available when `channelResistancePerMm > 0`;
///   * resistor serpentines — the component's through-flow, both engine modes;
///   * transistor source→drain bridges — ditto.
/// So with channel resistance off the overlay degrades to component-level
/// dots instead of disappearing.
///
/// Perf/observation constraints (see `SimulationClock` for the war story —
/// a `TimelineView` re-evaluating observable reads per frame stranded an
/// observation-tracking node per frame):
///   * the outer `body` reads `state.flows` once per ~20 Hz publish and asks
///     `FlowOverlayCache` for the plain-value draw list — geometry and screen
///     paths come from caches keyed by network revision / layer filter /
///     transform, so a publish only re-does the flow lookups;
///   * the per-frame Canvas closure reads only that list, the timeline date
///     and `state.elapsedSimSeconds` (`@ObservationIgnored` — no tracking),
///     strokes the pre-built `Path`s with a fresh dash phase, and culls to
///     the viewport;
///   * the timeline pauses whenever the sim does, so a paused Simulate tab
///     costs nothing and the dots freeze with sim-time (they also speed up
///     with the time-scale slider, like the air they represent).
struct FlowOverlayView: View {
    let state: SimulationState
    let flat: CircuitDocument
    let visible: LayerVisibility
    let transform: CanvasTransform
    /// Stroke width of the channel heatmap underneath, so dots sit inside it.
    let channelStroke: Double

    /// Staged caches (a class, so it survives body re-evaluation). Fresh per
    /// overlay identity — toggling Flow off and on just re-primes it.
    @State private var cache = FlowOverlayCache()

    var body: some View {
        let items = cache.drawList(
            flows: state.flows,
            network: state.network,
            networkRevision: state.networkRevision,
            flat: flat,
            visible: visible,
            transform: transform
        )
        let timeScale = state.params.timeScale
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !state.isPlaying)) { timeline in
            Canvas { ctx, size in
                _ = timeline.date   // drives the redraw; the phase clock is sim-time
                draw(items, in: &ctx, size: size,
                     clock: state.elapsedSimSeconds, timeScale: timeScale)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ items: [FlowOverlayCache.DrawItem],
                      in ctx: inout GraphicsContext, size: CGSize,
                      clock: Double, timeScale: Double) {
        let dotWidth = max(2.0, channelStroke * 0.5)
        let period = max(10.0, dotWidth * 4.5)
        // Dot pacing. The phase clock is sim-time (freezes on pause), but the
        // *wall* march rate follows √timeScale rather than timeScale and is
        // capped well under one dash period per frame: a dash pattern that
        // advances ≈ its period per frame wagon-wheels into dots that look
        // stuck, which is exactly what ×10–×20 sims did when the rate scaled
        // linearly. √ keeps "faster sim → faster dots" legible instead.
        let ts = max(0.1, timeScale)
        let maxWallSpeed = period * 30.0 / 3.5   // ≤ period/3.5 per frame at 30 fps
        // Cull in screen space, padded so a dash sliding in from just outside
        // the viewport doesn't pop.
        let viewport = CGRect(origin: .zero, size: size)
            .insetBy(dx: -period - dotWidth, dy: -period - dotWidth)
        for item in items {
            guard item.bounds.intersects(viewport) else { continue }
            // √ mapping compresses the decades between leak crawl and full
            // pump draw into a readable speed range.
            let wallSpeed = min(maxWallSpeed, 55.0 * item.strength.squareRoot() * ts.squareRoot())
            let phase = (clock * wallSpeed / ts).truncatingRemainder(dividingBy: period)
            ctx.stroke(
                item.path,
                with: .color(.orange.opacity(0.55 + 0.45 * item.strength)),
                // A hairline dash with round caps renders as a dot every
                // `period` points; sliding dashPhase marches the dots along
                // the path — sign flips with the flow direction.
                style: StrokeStyle(lineWidth: dotWidth, lineCap: .round,
                                   dash: [0.01, period - 0.01],
                                   dashPhase: item.reversed ? phase : -phase)
            )
        }
    }
}

/// Rebuild-only-when-stale caches behind `FlowOverlayView`.
///
/// The overlay used to rebuild every world polyline (spans split into visible
/// runs, resistor serpentines, transistor bridges) on each ~20 Hz flow
/// publish, then map every point to screen space and build fresh `Path`s on
/// every animation frame. None of that input changes at those rates: world
/// geometry changes only when the network is rebuilt or the layer filter
/// flips, and screen paths only when the pan/zoom transform moves. Caching
/// each stage where it actually changes leaves the per-publish work at "look
/// up each candidate's flow" and the per-frame work at "stroke the cached
/// paths with a new dash phase".
@MainActor
final class FlowOverlayCache {
    /// One path ready to stroke this publish: screen-space geometry plus the
    /// flow strength that colours it and paces its dots.
    struct DrawItem {
        let path: Path
        /// Screen-space bounds, for viewport culling.
        let bounds: CGRect
        /// |Q| / reference, clamped to 0…1.
        let strength: Double
        /// Flow runs last → first point; the dash phase flips sign so the
        /// dots march backwards along the same cached path.
        let reversed: Bool
    }

    /// Where a candidate path's flow figure comes from on each publish.
    private enum Source {
        case span(Int)           // index into channelGraph.spans / spanFlows
        case resistor(UUID)
        case transistor(UUID)
    }

    /// One drawable world-mm polyline that could carry flow, ordered so
    /// positive flow runs first → last (the solver's node1 → node2).
    private struct Candidate {
        let source: Source
        let points: [Point]
    }

    private var candidates: [Candidate] = []
    private var candidatesRevision: Int?
    private var candidatesVisibility: LayerVisibility?

    /// Screen-space path + bounds per candidate, index-aligned with
    /// `candidates`.
    private var screenPaths: [(path: Path, bounds: CGRect)] = []
    private var screenTransform: CanvasTransform?

    func drawList(
        flows: FlowReport,
        network: PneumaticNetwork,
        networkRevision: Int,
        flat: CircuitDocument,
        visible: LayerVisibility,
        transform: CanvasTransform
    ) -> [DrawItem] {
        if candidatesRevision != networkRevision || candidatesVisibility != visible {
            rebuildCandidates(network: network, flat: flat, visible: visible)
            candidatesRevision = networkRevision
            candidatesVisibility = visible
            screenTransform = nil
        }
        if screenTransform != transform {
            rebuildScreenPaths(transform: transform)
            screenTransform = transform
        }

        // Full scale = the pump's free-flow ceiling; boards with no pump
        // (bus-driven fixtures) fall back to the largest live flow so the
        // overlay still ranks paths sensibly.
        var qRef = flows.pumpFreeFlowMax
        if qRef <= 0 {
            qRef = max(flows.flowByResistor.values.map { abs($0) }.max() ?? 0,
                       flows.flowByTransistor.values.map { abs($0) }.max() ?? 0)
        }
        guard qRef > 0 else { return [] }
        let qMin = qRef * 0.01

        var items: [DrawItem] = []
        items.reserveCapacity(candidates.count)
        for (i, candidate) in candidates.enumerated() {
            let q: Double
            switch candidate.source {
            case .span(let s):        q = s < flows.spanFlows.count ? flows.spanFlows[s] : 0
            case .resistor(let id):   q = flows.flowByResistor[id] ?? 0
            case .transistor(let id): q = flows.flowByTransistor[id] ?? 0
            }
            guard abs(q) >= qMin else { continue }
            let screen = screenPaths[i]
            items.append(DrawItem(path: screen.path, bounds: screen.bounds,
                                  strength: min(1.0, abs(q) / qRef),
                                  reversed: q < 0))
        }
        return items
    }

    private func rebuildCandidates(
        network: PneumaticNetwork, flat: CircuitDocument, visible: LayerVisibility
    ) {
        var out: [Candidate] = []

        // Channel spans: split each retained polyline into contiguous visible
        // same-layer runs (layer changes are via bores — no length, nothing
        // to animate). One span can yield several runs; each reads the same
        // span flow on publish.
        for (i, span) in network.channelGraph.spans.enumerated() {
            guard span.polyline.count >= 2 else { continue }
            var run: [Point] = []
            for k in 1..<span.polyline.count {
                let a = span.polyline[k - 1], b = span.polyline[k]
                let drawable = a.layer == b.layer && visible.contains(a.layer)
                if drawable {
                    if run.isEmpty { run.append(a.p) }
                    run.append(b.p)
                } else if !run.isEmpty {
                    out.append(Candidate(source: .span(i), points: run))
                    run = []
                }
            }
            if run.count >= 2 { out.append(Candidate(source: .span(i), points: run)) }
        }

        // Component through-flows: the stream continues across resistor
        // serpentines and transistor bodies, and this is all the overlay has
        // when channel resistance is 0 (spanFlows empty).
        let componentById = Dictionary(flat.logic.components.map { ($0.id, $0) },
                                       uniquingKeysWith: { a, _ in a })
        for placement in flat.physical.placements {
            guard let component = componentById[placement.componentId],
                  visible.contains(Layer(plate: placement.layer, depth: placement.depth))
            else { continue }

            func world(_ local: Point) -> Point {
                let c = cos(placement.rotation.radians), s = sin(placement.rotation.radians)
                return Point(x: placement.position.x + local.x * c - local.y * s,
                             y: placement.position.y + local.x * s + local.y * c)
            }

            switch component.kind {
            case .resistor:
                // Serpentine runs pin 1 → pin 2, matching the flow's
                // node1 → node2 sign convention.
                let local = ResistorGeometry.waypoints(
                    for: component.resistorSize ?? .medium, m: flat.manufacturing
                )
                guard local.count >= 2 else { continue }
                out.append(Candidate(source: .resistor(component.id),
                                     points: local.map(world)))
            case .transistor:
                let fp = component.footprint(flat.manufacturing)
                guard let a = fp.pin("a"), let b = fp.pin("b") else { continue }
                out.append(Candidate(source: .transistor(component.id),
                                     points: [world(a.offset), world(b.offset)]))
            default:
                break
            }
        }
        candidates = out
    }

    private func rebuildScreenPaths(transform: CanvasTransform) {
        screenPaths = candidates.map { candidate in
            var path = Path()
            var minX = Double.infinity, minY = Double.infinity
            var maxX = -Double.infinity, maxY = -Double.infinity
            for (k, p) in candidate.points.enumerated() {
                let sp = transform.toScreen(p)
                if k == 0 { path.move(to: sp) } else { path.addLine(to: sp) }
                minX = min(minX, sp.x); minY = min(minY, sp.y)
                maxX = max(maxX, sp.x); maxY = max(maxY, sp.y)
            }
            let bounds = CGRect(x: minX, y: minY,
                                width: max(0, maxX - minX), height: max(0, maxY - minY))
            return (path, bounds)
        }
    }
}
