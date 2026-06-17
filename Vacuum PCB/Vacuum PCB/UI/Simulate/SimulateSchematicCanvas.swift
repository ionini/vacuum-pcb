import SwiftUI

/// Read-only schematic-style heatmap for the Simulate tab. Reuses the same
/// pin-offset geometry as the editing canvas so symbol positions match, but
/// renders without any drag / select / route affordances and tints both nets
/// and component symbols by their current simulated pressure.
///
/// This outer view owns only the pan/zoom shell. It deliberately reads *no*
/// per-tick simulation state, so it isn't re-evaluated when pressures change —
/// that keeps `SimulatePanZoom` (and its `NSViewRepresentable` gesture/scroll
/// catchers) stable. All the live drawing lives in `SchematicCanvasLayer`,
/// which is the only thing that re-renders on a pressure publish.
struct SimulateSchematicCanvas: View {
    let document: CircuitDocument
    @Bindable var state: SimulationState

    var body: some View {
        SimulatePanZoom(fit: fit) {
            SchematicCanvasLayer(document: document, state: state)
        }
    }

    // MARK: - Fit

    /// Compute the initial zoom + pan that frames every component in the
    /// viewport with a comfortable margin. Falls back to identity for empty
    /// documents.
    private func fit(in viewSize: CGSize) -> (zoom: Double, pan: CGSize) {
        let positions = document.logic.components
            .filter { $0.kind != .screw }
            .compactMap { document.schematic.position(for: $0.id) }
        guard !positions.isEmpty, viewSize.width > 40, viewSize.height > 40 else {
            return (1.0, .zero)
        }
        let pad: Double = 70
        let minX = positions.map(\.x).min()! - pad
        let maxX = positions.map(\.x).max()! + pad
        let minY = positions.map(\.y).min()! - pad
        let maxY = positions.map(\.y).max()! + pad
        let w = max(1, maxX - minX), h = max(1, maxY - minY)
        let margin: Double = 24
        let availW = max(1, Double(viewSize.width) - 2 * margin)
        let availH = max(1, Double(viewSize.height) - 2 * margin)
        let scale = min(availW / w, availH / h, 2.0)
        let pan = CGSize(
            width: (Double(viewSize.width) - w * scale) / 2 - minX * scale,
            height: (Double(viewSize.height) - h * scale) / 2 - minY * scale
        )
        return (scale, pan)
    }
}

/// The live, pressure-driven drawing layer. The whole schematic — net lines,
/// mating bus-lines, and every component symbol with its label — is drawn in a
/// single `Canvas`. Drawing imperatively (rather than as a `ForEach` of
/// positioned SwiftUI views) keeps the symbols out of the SwiftUI attribute
/// graph: a pressure change re-runs one draw closure instead of invalidating,
/// re-diffing, and re-laying-out one view per component.
///
/// This is a separate `View` from `SimulateSchematicCanvas` on purpose: reading
/// the observable simulation state *here* scopes the re-render to this leaf, so
/// the surrounding pan/zoom shell isn't re-evaluated on every publish.
private struct SchematicCanvasLayer: View {
    let document: CircuitDocument
    let state: SimulationState
    /// Mirrors the schematic editor's rail-tap toggle (same AppStorage key) so
    /// the Simulate view shows VAC/ATM the same way.
    @AppStorage("schematicShowRailTaps") private var showRailTaps = true

    var body: some View {
        // Snapshot the observable simulation state once per render. Reading
        // these as locals (not inside the Canvas draw closure) ties this view's
        // redraw to pressure changes and collapses what would otherwise be
        // O(pins) `@Observable` registrar accesses per frame down to three
        // property reads.
        let pressures = state.pressureByNet
        let remap = state.netIdRemap
        let openness = state.transistorOpenness

        return Canvas { ctx, _ in
            drawNets(in: ctx, pressures: pressures, remap: remap)
            drawMatings(in: ctx)
            drawComponents(in: ctx, pressures: pressures, remap: remap, openness: openness)
        }
        .allowsHitTesting(false)
    }

    // MARK: - Drawing

    /// One stroked line per net edge, coloured by the net's current pressure.
    /// Layout rules live in `NetEdgeBuilder`, so the look matches the editor.
    private func drawNets(in ctx: GraphicsContext, pressures: [UUID: Double], remap: [UUID: UUID]) {
        for net in SchematicWireGeometry.render(in: document, railTaps: showRailTaps) {
            let pressure = rawNetPressure(net.netId, pressures: pressures, remap: remap)
            let stroke = PressureColor.strokeColor(for: pressure)
            for edge in net.edges {
                ctx.stroke(
                    WireRouter.roundedPath(edge.points, radius: 9),
                    with: .color(stroke),
                    style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round)
                )
            }
            for tap in net.taps {
                drawSimTap(in: ctx, tap, color: stroke)
            }
        }
    }

    /// A rail tap in the simulator, coloured by the net's pressure (stub + bar,
    /// no label — the editor carries the VAC/ATM text).
    private func drawSimTap(in ctx: GraphicsContext, _ tap: SchematicWireGeometry.Tap, color: Color) {
        let stub: CGFloat = 12, half: CGFloat = 7
        let v = tap.exit.vector
        let end = CGPoint(x: tap.point.x + v.x * stub, y: tap.point.y + v.y * stub)
        let perp = tap.exit.isHorizontal ? CGPoint(x: 0, y: 1) : CGPoint(x: 1, y: 0)
        var stubPath = Path()
        stubPath.move(to: tap.point)
        stubPath.addLine(to: end)
        var bar = Path()
        bar.move(to: CGPoint(x: end.x - perp.x * half, y: end.y - perp.y * half))
        bar.addLine(to: CGPoint(x: end.x + perp.x * half, y: end.y + perp.y * half))
        ctx.stroke(stubPath, with: .color(color), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
        ctx.stroke(bar, with: .color(color), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
    }

    /// Mating bus-lines paint on top of the nets in indigo so the user still
    /// sees that two connectors are snapped together — the surrounding nets
    /// animate the pressure flow, the bus-line marks the join.
    private func drawMatings(in ctx: GraphicsContext) {
        for mating in document.logic.matings {
            guard let a = MatingEndpointGeometry.point(for: mating.a, in: document),
                  let b = MatingEndpointGeometry.point(for: mating.b, in: document)
            else { continue }
            let da = MatingEndpointGeometry.exit(for: mating.a, selfPoint: a, otherPoint: b, in: document)
            let db = MatingEndpointGeometry.exit(for: mating.b, selfPoint: b, otherPoint: a, in: document)
            ctx.stroke(
                WireRouter.roundedPath(WireRouter.route(from: a, da, to: b, db), radius: 9),
                with: .color(.indigo.opacity(0.75)),
                style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round)
            )
        }
    }

    /// Every component symbol, tinted by its pressure, with the editor's
    /// metrics so positions and sizes line up exactly. Screws are mechanical
    /// only and never drawn on the schematic.
    private func drawComponents(
        in ctx: GraphicsContext,
        pressures: [UUID: Double],
        remap: [UUID: UUID],
        openness: [UUID: Double]
    ) {
        for component in document.logic.components where component.kind != .screw {
            let pos = document.schematic.position(for: component.id) ?? Point(x: 200, y: 200)
            let center = CGPoint(x: pos.x, y: pos.y)
            let metrics = ComponentSymbolMetrics
                .metrics(for: component, snapshots: document.librarySnapshots)
                .rotated(by: document.schematic.rotation(for: component.id))
            let pressure = nodePressure(component: component, pressures: pressures, remap: remap)
            let fill = PressureColor.color(for: pressure).opacity(0.55)
            let stroke = PressureColor.strokeColor(for: pressure)

            let rect = CGRect(
                x: center.x - metrics.size.width / 2,
                y: center.y - metrics.size.height / 2,
                width: metrics.size.width,
                height: metrics.size.height
            )
            let path = symbolPath(component.kind, in: rect)
            ctx.fill(path, with: .color(fill))
            ctx.stroke(path, with: .color(stroke), lineWidth: 1.5)

            drawLabel(in: ctx, component: component, center: center,
                      pressure: pressure, openness: openness)
        }
    }

    /// The component label, with its per-kind readout stacked underneath —
    /// mirrors the old `VStack(spacing: 1)` of two `Text`s centred over the
    /// symbol.
    private func drawLabel(
        in ctx: GraphicsContext,
        component: Component,
        center: CGPoint,
        pressure: Double,
        openness: [UUID: Double]
    ) {
        let unbounded = CGSize(width: 1000, height: 1000)
        var label = ctx.resolve(Text(component.label).font(.system(size: 12, weight: .semibold)))
        label.shading = .color(.primary)
        let labelSize = label.measure(in: unbounded)

        guard let annotationText = annotation(for: component, pressure: pressure, openness: openness) else {
            ctx.draw(label, at: center, anchor: .center)
            return
        }
        var annotation = ctx.resolve(annotationText.font(.system(size: 9)))
        annotation.shading = .color(.secondary)
        let annotationSize = annotation.measure(in: unbounded)

        let spacing: CGFloat = 1
        let totalHeight = labelSize.height + spacing + annotationSize.height
        ctx.draw(label,
                 at: CGPoint(x: center.x, y: center.y - totalHeight / 2 + labelSize.height / 2),
                 anchor: .center)
        ctx.draw(annotation,
                 at: CGPoint(x: center.x, y: center.y + totalHeight / 2 - annotationSize.height / 2),
                 anchor: .center)
    }

    /// Symbol outline per kind — mirrors the shapes the editor uses so the
    /// simulator's symbols match the schematic's.
    private func symbolPath(_ kind: ComponentKind, in rect: CGRect) -> Path {
        switch kind {
        case .transistor, .screw, .led:
            return Path(ellipseIn: rect)
        case .resistor, .subpart:
            return Path(roundedRect: rect, cornerRadius: 6)
        case .vacuumSource, .atmVent, .port, .connector:
            return Path(roundedRect: rect, cornerRadius: 4)
        }
    }

    // MARK: - Pressure lookup (reads the per-render snapshot, not @Observable)

    /// Pressure of a net identified by its *unflattened* id, resolving the
    /// flatten's net merges first. Mirrors `SimulationState.pressure(rawNet:)`
    /// but against the snapshot captured in `body`.
    private func rawNetPressure(_ netId: UUID, pressures: [UUID: Double], remap: [UUID: UUID]) -> Double {
        pressures[remap[netId] ?? netId] ?? 1.0
    }

    private func netPressure(pin: PinRef, pressures: [UUID: Double], remap: [UUID: UUID]) -> Double {
        guard let netId = document.logic.nets.first(where: { $0.pins.contains(pin) })?.id
        else { return 1.0 }
        return rawNetPressure(netId, pressures: pressures, remap: remap)
    }

    /// Pressure to tint a component by — usually its "primary" pin's net
    /// pressure (gate for transistor, "p" for ports/rails/LEDs, midpoint for
    /// resistor). Subparts/connectors average their pins.
    private func nodePressure(component: Component, pressures: [UUID: Double], remap: [UUID: UUID]) -> Double {
        switch component.kind {
        case .transistor:
            return netPressure(pin: PinRef(componentId: component.id, pinKey: "gate"),
                               pressures: pressures, remap: remap)
        case .resistor:
            // Resistors visually drift between their two end-pressures; mean
            // works well for the eye when the user is reading a divider.
            let a = netPressure(pin: PinRef(componentId: component.id, pinKey: "1"),
                                pressures: pressures, remap: remap)
            let b = netPressure(pin: PinRef(componentId: component.id, pinKey: "2"),
                                pressures: pressures, remap: remap)
            return (a + b) / 2
        case .vacuumSource: return 0
        case .atmVent:      return 1
        case .port, .led:
            return netPressure(pin: PinRef(componentId: component.id, pinKey: "p"),
                               pressures: pressures, remap: remap)
        case .subpart:
            // Library-driven boundary pins live in `Component.pinKeys`.
            // Average their net pressures so the symbol's tint reflects the
            // overall state of the subpart's external connections.
            let keys = component.pinKeys(snapshots: document.librarySnapshots)
            guard !keys.isEmpty else { return 1 }
            let sum = keys.reduce(0.0) {
                $0 + netPressure(pin: PinRef(componentId: component.id, pinKey: $1),
                                 pressures: pressures, remap: remap)
            }
            return sum / Double(keys.count)
        case .screw: return 1
        case .connector:
            // Average every connector pin's net pressure so the symbol tint
            // reflects the rail-level state of the mating side.
            let n = max(1, component.connectorPinCount ?? 1)
            let sum = (1...n).reduce(0.0) {
                $0 + netPressure(pin: PinRef(componentId: component.id, pinKey: "\($1)"),
                                 pressures: pressures, remap: remap)
            }
            return sum / Double(n)
        }
    }

    // MARK: - Annotation

    /// Per-component readout drawn under the label. Output ports / LEDs / probes
    /// show their numeric pressure; transistors show the open fraction so the
    /// user can correlate a gate change with a state flip. Returns `nil` for
    /// kinds with no readout (screws, which aren't drawn anyway).
    private func annotation(for component: Component, pressure: Double, openness: [UUID: Double]) -> Text? {
        let formatted = PressureColor.formatted(pressure)
        switch component.kind {
        case .port:
            return Text(component.portDirection == .input ? "IN \(formatted)" : "OUT \(formatted)")
        case .led:
            return Text("LED \(formatted)")
        case .vacuumSource:
            return Text("VAC")
        case .atmVent:
            return Text("ATM")
        case .transistor:
            let fraction = openness[component.id] ?? 0
            return Text(String(format: "Q %.0f%%", fraction * 100))
        case .resistor:
            if let size = component.resistorSize {
                return Text("\(size.rawValue) · \(formatted)")
            }
            return Text(formatted)
        case .subpart:
            return Text(formatted)
        case .screw:
            return nil
        case .connector:
            let n = component.connectorPinCount ?? 1
            return Text("J \(n)P · \(formatted)")
        }
    }
}
