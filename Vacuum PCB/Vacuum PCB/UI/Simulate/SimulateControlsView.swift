import SwiftUI

/// Sidebar block shown on the Simulate tab. Lists every input port with a
/// vacuum / atmosphere toggle, every probe (output port / LED) with a live
/// pressure readout, and every transistor with a percentage open indicator.
///
/// Lives in the DocumentView sidebar (alongside DRC) following the same
/// pattern the 3D Preview tab uses to park its manufacturing sliders there.
/// Three-way drive state for a bidirectional (bus) connector pin, mapped to
/// the `Double` the solver stores in `SimulationState.inputPressures`:
/// `NaN` = floating (drive nothing), `1.0` = atmosphere, `0.0` = vacuum. The
/// solver reads any non-NaN value `< 0.5` as a Vac drive, so `0.0` is just a
/// convenient canonical "Vac".
private enum BusDrive: Hashable {
    case float, vac, atm

    var storedValue: Double {
        switch self {
        case .float: return .nan
        case .vac:   return 0.0
        case .atm:   return 1.0
        }
    }

    static func from(_ value: Double?) -> BusDrive {
        guard let value, !value.isNaN else { return .float }
        return value < 0.5 ? .vac : .atm
    }
}

struct SimulateControlsView: View {
    @Bindable var state: SimulationState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()
            Text("Simulate")
                .font(.headline)
            tuning
            inputs
            probes
            transistors
            netList
        }
    }

    /// Two sliders we surface for interactive calibration. The defaults
    /// produce sensible behaviour on the canonical inverter, but real
    /// pneumatic devices have wildly varying restrictions, and the gate
    /// "threshold" is the cleanest knob for adjusting how much vacuum the
    /// silicone needs to commit to a switch.
    @ViewBuilder private var tuning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tuning").font(.subheadline).bold()
            tuningSlider(
                label: "R / mm",
                help: "Resistance per mm of channel inside a resistor. " +
                      "Lower = pressure equalises faster through resistors.",
                value: $state.params.resistorResistancePerMm,
                range: 0.05...4.0,
                format: "%.2f"
            )
            tuningSlider(
                label: "Gate at",
                help: "Pressure at which a transistor's source-drain path " +
                      "is half-open. Lower = needs more vacuum on the gate " +
                      "to activate.",
                value: $state.params.gateThreshold,
                range: 0.05...0.9,
                format: "%.2f"
            )
            pumpTuning
        }
    }

    /// Three sliders modelling the real vacuum pump's Q-vs-P curve. The
    /// previous solver treated VAC sources as ideal anchors at zero — useful
    /// for crisp digital simulations, but it hid leakage losses that matter
    /// the moment a real (finite-flow) pump is wired up. Defaults are tuned
    /// to roughly preserve the old "infinite" behaviour; dial flow capacity
    /// down to see how much vacuum the resistors are actually draining.
    @ViewBuilder private var pumpTuning: some View {
        if !state.network.pumps.isEmpty {
            Text("Pump").font(.subheadline).bold().padding(.top, 4)
            tuningSlider(
                label: "Max vac",
                help: "Deepest scaled pressure the pump can pull at zero " +
                      "flow (deadhead). 0 = perfect vacuum; 0.2 = pump " +
                      "asymptotes to 20% of atmosphere.",
                value: $state.params.pumpMaxVacuum,
                range: 0.0...0.8,
                format: "%.2f"
            )
            tuningSlider(
                label: "Flow",
                help: "Pump conductance at free flow (net at atmosphere). " +
                      "Higher = the pump can overcome more resistor leakage " +
                      "and drag the source net closer to max vacuum. Lower " +
                      "to model an underpowered pump.",
                value: $state.params.pumpFlowCapacity,
                range: 0.5...50.0,
                format: "%.1f"
            )
            tuningSlider(
                label: "Droop",
                help: "Q-vs-P curve shape. 0 = linear. >0 = concave (pump " +
                      "struggles near deadhead). <0 = convex (pump holds " +
                      "flow in the middle, then knees down near max vacuum) " +
                      "— measured pumps often look like this.",
                value: $state.params.pumpDroopExponent,
                range: -0.9...3.0,
                format: "%.2f"
            )
        }
    }

    private func tuningSlider(
        label: String,
        help: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String
    ) -> some View {
        // `.controlSize(.small)` and the tight label/value frames work for
        // a cursor on macOS but make the thumb almost unhittable with a
        // finger. On iPad we keep the regular control size and give the
        // text columns a bit more room.
        let labelWidth: CGFloat = InputPlatform.isTouch ? 60 : 46
        let valueWidth: CGFloat = InputPlatform.isTouch ? 48 : 36
        return HStack(spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: valueWidth, alignment: .trailing)
        }
        .help(help)
    }

    @ViewBuilder
    private func slider(value: Binding<Double>, in range: ClosedRange<Double>) -> some View {
        if InputPlatform.isTouch {
            Slider(value: value, in: range)
        } else {
            Slider(value: value, in: range).controlSize(.small)
        }
    }

    @ViewBuilder private var inputs: some View {
        if state.network.inputs.isEmpty {
            Text("No input ports — add a port with direction IN to drive the circuit.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Text("Inputs").font(.subheadline).bold()
            ForEach(state.network.inputs) { input in
                inputRow(input: input)
            }
        }
    }

    @ViewBuilder
    private func inputRow(input: PneumaticNetwork.Input) -> some View {
        if input.soft {
            softInputRow(input)
        } else {
            hardInputRow(input)
        }
    }

    private func hardInputRow(_ input: PneumaticNetwork.Input) -> some View {
        let current = state.inputPressures[input.id] ?? 1.0
        // Treat the toggle as boolean (Vac / Atm). Internally we still store
        // a Double so the underlying solver doesn't need a special case for
        // discrete signals — the user just can't dial in 0.3 from this UI.
        let isVacuum = current < 0.5
        return HStack(spacing: 8) {
            Text(input.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Picker("", selection: Binding(
                get: { isVacuum },
                set: { state.inputPressures[input.id] = $0 ? 0.0 : 1.0 }
            )) {
                Text("Vac").tag(true)
                Text("Atm").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 110)
            Spacer()
            Circle()
                .fill(PressureColor.color(for: current))
                .frame(width: 12, height: 12)
        }
    }

    /// A bidirectional (bus) connector pin. Three-way drive: Float (high-Z,
    /// the default — drives nothing, just reads), Vac, or Atm, applied
    /// through the solver's soft conductance so an on-board driver can still
    /// win. The indicator shows the *net's* current pressure, not the drive
    /// setting, since the whole point is that the pin reads whatever the bus
    /// settles to.
    private func softInputRow(_ input: PneumaticNetwork.Input) -> some View {
        let netPressure = state.pressure(net: input.netId)
        return HStack(spacing: 8) {
            Text(input.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Picker("", selection: Binding(
                get: { BusDrive.from(state.inputPressures[input.id]) },
                set: { state.inputPressures[input.id] = $0.storedValue }
            )) {
                Text("Float").tag(BusDrive.float)
                Text("Vac").tag(BusDrive.vac)
                Text("Atm").tag(BusDrive.atm)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Spacer()
            Circle()
                .fill(PressureColor.color(for: netPressure))
                .frame(width: 12, height: 12)
        }
    }

    @ViewBuilder private var probes: some View {
        if !state.network.probes.isEmpty {
            Text("Probes").font(.subheadline).bold()
            ForEach(state.network.probes) { probe in
                probeRow(probe: probe)
            }
        }
    }

    private func probeRow(probe: PneumaticNetwork.Probe) -> some View {
        let pressure = state.pressure(probe: probe)
        return HStack(spacing: 8) {
            Image(systemName: probe.kind == .led ? "lightbulb" : "dot.circle")
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(probe.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Text(PressureColor.formatted(pressure))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.primary)
                .frame(width: 38, alignment: .trailing)
            ProgressView(value: pressure)
                .progressViewStyle(.linear)
                .tint(PressureColor.strokeColor(for: pressure))
                .animation(nil, value: pressure)
        }
    }

    @ViewBuilder private var transistors: some View {
        if !state.network.transistors.isEmpty {
            Text("Transistors").font(.subheadline).bold()
            ForEach(state.network.transistors) { t in
                transistorRow(t)
            }
        }
    }

    private func transistorRow(_ t: PneumaticNetwork.TransistorEdge) -> some View {
        let openness = state.transistorOpenness[t.id] ?? 0
        let gateP = state.pressure(net: t.gateNet)
        return HStack(spacing: 8) {
            Text(t.label)
                .font(.system(size: 12, weight: .medium).monospaced())
                .frame(width: 56, alignment: .leading)
            Text(openness > 0.5 ? "open" : "closed")
                .font(.caption)
                .foregroundStyle(openness > 0.5 ? .green : .secondary)
                .frame(width: 44, alignment: .leading)
            Spacer()
            Text("g=\(PressureColor.formatted(gateP))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    /// Compact net list at the bottom — every net with its current pressure.
    /// Useful for debugging dividers and unanchored floats.
    @ViewBuilder private var netList: some View {
        if !state.network.nets.isEmpty {
            Divider()
            DisclosureGroup("Nets (\(state.network.nets.count))") {
                ForEach(state.network.nets) { net in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(PressureColor.color(for: state.pressure(net: net.id)))
                            .frame(width: 10, height: 10)
                        Text(net.label)
                            .font(.caption.monospacedDigit())
                            .lineLimit(1)
                        Spacer()
                        Text(PressureColor.formatted(state.pressure(net: net.id)))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
    }
}
