import SwiftUI

/// Read-only schematic-style heatmap for the Simulate tab. Reuses the same
/// pin-offset geometry as the editing canvas so symbol positions match, but
/// renders without any drag / select / route affordances and tints both nets
/// and component symbols by their current simulated pressure.
///
/// Stays self-contained instead of layering on top of `SchematicCanvasView`
/// because the editor's gesture stack would happily start a marquee or pin
/// drag from inside Simulate — easier to write a small fresh canvas than to
/// thread "simulate mode" through every editor branch.
struct SimulateSchematicCanvas: View {
    let document: CircuitDocument
    @Bindable var state: SimulationState

    var body: some View {
        SimulatePanZoom(fit: fit) {
            ZStack(alignment: .topLeading) {
                netLinesLayer
                ForEach(document.logic.components.filter { $0.kind != .screw }) { component in
                    let pos = document.schematic.position(for: component.id) ?? Point(x: 200, y: 200)
                    componentNode(component: component)
                        .position(x: pos.x, y: pos.y)
                }
            }
        }
    }

    /// One Canvas pass for every net, drawing edges in the pressure-derived
    /// colour of that net. Layout rules mirror `NetEdgeBuilder`, so the look
    /// of the schematic matches the editor exactly. Mating bus-lines paint
    /// on top in indigo so the user still sees that two connectors are
    /// snapped together — the surrounding nets animate the pressure flow,
    /// the bus-line marks the join.
    private var netLinesLayer: some View {
        Canvas { ctx, _ in
            for net in document.logic.nets {
                let pressure = state.pressure(net: net.id)
                let stroke = PressureColor.strokeColor(for: pressure)
                for edge in NetEdgeBuilder.edges(for: net, in: document) {
                    var path = Path()
                    path.move(to: edge.a.point)
                    path.addLine(to: edge.b.point)
                    ctx.stroke(path, with: .color(stroke), lineWidth: 2.4)
                }
            }
            for mating in document.logic.matings {
                guard let a = MatingEndpointGeometry.point(for: mating.a, in: document),
                      let b = MatingEndpointGeometry.point(for: mating.b, in: document)
                else { continue }
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(
                    path,
                    with: .color(.indigo.opacity(0.75)),
                    style: StrokeStyle(lineWidth: 4.5, lineCap: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    /// One component symbol re-skinned for the simulator. Borrows the
    /// editor's metrics so positions and pin offsets line up exactly.
    @ViewBuilder
    private func componentNode(component: Component) -> some View {
        let metrics = ComponentSymbolMetrics.metrics(for: component, snapshots: document.librarySnapshots)
        let pressure = nodePressure(component: component)
        let fill = PressureColor.color(for: pressure).opacity(0.55)
        let stroke = PressureColor.strokeColor(for: pressure)
        ZStack {
            symbolShape(component.kind)
                .fill(fill)
                .overlay(symbolShape(component.kind).stroke(stroke, lineWidth: 1.5))
                .frame(width: metrics.size.width, height: metrics.size.height)
            VStack(spacing: 1) {
                Text(component.label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                annotation(for: component, pressure: pressure)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: metrics.size.width, height: metrics.size.height)
        .allowsHitTesting(false)
    }

    private func symbolShape(_ kind: ComponentKind) -> AnyShape {
        switch kind {
        case .transistor: AnyShape(Circle())
        case .resistor:   AnyShape(RoundedRectangle(cornerRadius: 6))
        case .vacuumSource, .atmVent, .port:
                          AnyShape(RoundedRectangle(cornerRadius: 4))
        case .subpart:    AnyShape(RoundedRectangle(cornerRadius: 6))
        case .screw:      AnyShape(Circle())
        case .led:        AnyShape(Circle())
        case .connector:  AnyShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    /// Pressure to tint a component by — usually its "primary" pin's net
    /// pressure (gate for transistor, "p" for ports/rails/LEDs, midpoint for
    /// resistor). Subparts default to atmosphere since their internals are
    /// opaque in v1.
    private func nodePressure(component: Component) -> Double {
        switch component.kind {
        case .transistor:
            return netPressure(pin: PinRef(componentId: component.id, pinKey: "gate"))
        case .resistor:
            // Resistors visually drift between their two end-pressures; mean
            // works well for the eye when the user is reading a divider.
            let a = netPressure(pin: PinRef(componentId: component.id, pinKey: "1"))
            let b = netPressure(pin: PinRef(componentId: component.id, pinKey: "2"))
            return (a + b) / 2
        case .vacuumSource: return 0
        case .atmVent:      return 1
        case .port, .led:
            return netPressure(pin: PinRef(componentId: component.id, pinKey: "p"))
        case .subpart:
            // Library-driven boundary pins live in `Component.pinKeys`.
            // Average their net pressures so the symbol's tint reflects
            // the overall state of the subpart's external connections.
            let keys = component.pinKeys(snapshots: document.librarySnapshots)
            guard !keys.isEmpty else { return 1 }
            let sum = keys.reduce(0.0) {
                $0 + netPressure(pin: PinRef(componentId: component.id, pinKey: $1))
            }
            return sum / Double(keys.count)
        case .screw: return 1
        case .connector:
            // Average every connector pin's net pressure so the symbol tint
            // reflects the rail-level state of the mating side.
            let n = max(1, component.connectorPinCount ?? 1)
            let sum = (1...n).reduce(0.0) {
                $0 + netPressure(pin: PinRef(componentId: component.id, pinKey: "\($1)"))
            }
            return sum / Double(n)
        }
    }

    private func netPressure(pin: PinRef) -> Double {
        guard let netId = document.logic.nets.first(where: { $0.pins.contains(pin) })?.id
        else { return 1.0 }
        return state.pressure(net: netId)
    }

    /// Per-component readout under the label. Output ports / LEDs / probes
    /// always show their numeric pressure; transistors show the open
    /// fraction so the user can correlate a gate change with a state flip.
    @ViewBuilder
    private func annotation(for component: Component, pressure: Double) -> some View {
        switch component.kind {
        case .port:
            if component.portDirection == .input {
                Text("IN \(PressureColor.formatted(pressure))")
            } else {
                Text("OUT \(PressureColor.formatted(pressure))")
            }
        case .led:
            Text("LED \(PressureColor.formatted(pressure))")
        case .vacuumSource: Text("VAC")
        case .atmVent: Text("ATM")
        case .transistor:
            let openness = state.transistorOpenness[component.id] ?? 0
            Text(String(format: "Q %.0f%%", openness * 100))
        case .resistor:
            if let size = component.resistorSize {
                Text("\(size.rawValue) · \(PressureColor.formatted(pressure))")
            } else {
                Text(PressureColor.formatted(pressure))
            }
        case .subpart:
            Text(PressureColor.formatted(pressure))
        case .screw:
            EmptyView()
        case .connector:
            let n = component.connectorPinCount ?? 1
            Text("J \(n)P · \(PressureColor.formatted(pressure))")
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
