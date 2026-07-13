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
///   * the outer `body` reads `state.flows` once per ~20 Hz publish and bakes
///     a plain-value `FlowOverlayModel`;
///   * the per-frame Canvas closure reads only that value, the timeline date
///     and `state.elapsedSimSeconds` (`@ObservationIgnored` — no tracking);
///   * the timeline pauses whenever the sim does, so a paused Simulate tab
///     costs nothing and the dots freeze with sim-time (they also scale with
///     the time-scale slider, like the air they represent).
struct FlowOverlayView: View {
    let state: SimulationState
    let flat: CircuitDocument
    let visible: LayerVisibility
    let transform: CanvasTransform
    /// Stroke width of the channel heatmap underneath, so dots sit inside it.
    let channelStroke: Double

    var body: some View {
        let model = FlowOverlayModel.build(
            flows: state.flows,
            network: state.network,
            flat: flat,
            visible: visible
        )
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !state.isPlaying)) { timeline in
            Canvas { ctx, _ in
                _ = timeline.date   // drives the redraw; the phase clock is sim-time
                draw(model, in: &ctx, clock: state.elapsedSimSeconds)
            }
        }
        .allowsHitTesting(false)
    }

    private func draw(_ model: FlowOverlayModel, in ctx: inout GraphicsContext, clock: Double) {
        let dotWidth = max(2.0, channelStroke * 0.5)
        let period = max(10.0, dotWidth * 4.5)
        for flowPath in model.paths {
            let pts = flowPath.points.map { transform.toScreen($0) }
            guard pts.count >= 2 else { continue }
            var path = Path()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            // √ mapping compresses the decades between leak crawl and full
            // pump draw into a readable speed range.
            let speed = 55.0 * flowPath.strength.squareRoot()
            let phase = (clock * speed).truncatingRemainder(dividingBy: period)
            ctx.stroke(
                path,
                with: .color(.orange.opacity(0.55 + 0.45 * flowPath.strength)),
                // A hairline dash with round caps renders as a dot every
                // `period` points; sliding dashPhase marches the dots along
                // the path in the flow direction.
                style: StrokeStyle(lineWidth: dotWidth, lineCap: .round,
                                   dash: [0.01, period - 0.01], dashPhase: -phase)
            )
        }
    }
}

/// Plain-value snapshot the overlay animates: every flowing path as a
/// world-mm polyline oriented in the flow direction, with a normalized
/// strength. Rebuilt once per pressure publish (~20 Hz), never per frame.
struct FlowOverlayModel {
    struct FlowPath {
        /// Board-mm points, ordered so the flow runs first → last.
        let points: [Point]
        /// |Q| / reference, clamped to 0…1.
        let strength: Double
    }
    let paths: [FlowPath]

    static func build(
        flows: FlowReport,
        network: PneumaticNetwork,
        flat: CircuitDocument,
        visible: LayerVisibility
    ) -> FlowOverlayModel {
        // Full scale = the pump's free-flow ceiling; boards with no pump
        // (bus-driven fixtures) fall back to the largest live flow so the
        // overlay still ranks paths sensibly.
        var qRef = flows.pumpFreeFlowMax
        if qRef <= 0 {
            qRef = max(flows.flowByResistor.values.map { abs($0) }.max() ?? 0,
                       flows.flowByTransistor.values.map { abs($0) }.max() ?? 0)
        }
        guard qRef > 0 else { return FlowOverlayModel(paths: []) }
        let qMin = qRef * 0.01

        var paths: [FlowPath] = []
        func add(_ points: [Point], q: Double) {
            guard abs(q) >= qMin, points.count >= 2 else { return }
            let strength = min(1.0, abs(q) / qRef)
            paths.append(FlowPath(points: q < 0 ? points.reversed() : points,
                                  strength: strength))
        }

        // Channel spans: split each retained polyline into contiguous
        // visible same-layer runs (layer changes are via bores — no length,
        // nothing to animate).
        let graph = network.channelGraph
        for (span, q) in zip(graph.spans, flows.spanFlows) {
            guard abs(q) >= qMin, span.polyline.count >= 2 else { continue }
            var run: [Point] = []
            for k in 1..<span.polyline.count {
                let a = span.polyline[k - 1], b = span.polyline[k]
                let drawable = a.layer == b.layer && visible.contains(a.layer)
                if drawable {
                    if run.isEmpty { run.append(a.p) }
                    run.append(b.p)
                } else if !run.isEmpty {
                    add(run, q: q)
                    run = []
                }
            }
            add(run, q: q)
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
                guard let q = flows.flowByResistor[component.id] else { continue }
                // Serpentine runs pin 1 → pin 2, matching the flow's
                // node1 → node2 sign convention.
                let local = ResistorGeometry.path(
                    transitions: ResistorGeometry.transitions(for: component.resistorSize ?? .medium),
                    halfLen: ManufacturingConstants.resistorFootprintLength / 2,
                    halfWid: ManufacturingConstants.resistorFootprintWidth / 2
                )
                add(local.map(world), q: q)
            case .transistor:
                guard let q = flows.flowByTransistor[component.id] else { continue }
                let fp = component.footprint(flat.manufacturing)
                guard let a = fp.pin("a"), let b = fp.pin("b") else { continue }
                add([world(a.offset), world(b.offset)], q: q)
            default:
                break
            }
        }

        return FlowOverlayModel(paths: paths)
    }
}
