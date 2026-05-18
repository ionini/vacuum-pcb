import Foundation
import Observation

/// Observable container for the live state of one Simulate tab.
///
/// Owns the network rebuild trigger, the integrator's current pressures /
/// transistor open fractions, the user's input port toggles, and the
/// play/pause / time-scale transport controls. Re-created when the user
/// leaves and returns to the Simulate tab (no persistence into the .vpcb).
@Observable
@MainActor
final class SimulationState {
    /// Current latched pneumatic network. Rebuilt whenever the document
    /// changes; the user's input settings carry over by component id.
    private(set) var network: PneumaticNetwork

    /// Subpart-flattened snapshot of the document, cached so the
    /// rendering layer can iterate the inlined primitives without paying
    /// the flatten cost every frame. Updated alongside `network`.
    private(set) var flattenedDoc: CircuitDocument

    var params: SimulationParameters = .defaults

    /// User-controlled input port pressures keyed by input component id.
    /// Default 1.0 (atmosphere) for any input not yet toggled.
    var inputPressures: [UUID: Double] = [:]

    /// Net pressure (0 = vacuum, 1 = atm) keyed by net id. Initialised to
    /// atmosphere everywhere, then refined by the integrator.
    var pressureByNet: [UUID: Double] = [:]

    /// Per-transistor 0…1 "open fraction" for UI rendering. Mirrors the
    /// conductance ramp around the gate threshold.
    var transistorOpenness: [UUID: Double] = [:]

    /// Whether the integrator advances on each clock tick.
    var isPlaying: Bool = true

    /// Sim-time accumulator so the engine takes fixed steps even when the
    /// view's clock tick is jittery. Drained on each tick.
    private var simAccumulator: Double = 0

    init(document: CircuitDocument) {
        let flattened = document.flattenedForSimulation()
        self.flattenedDoc = flattened
        self.network = PneumaticNetwork.build(from: flattened)
        self.pressureByNet = initialPressures(for: network)
    }

    /// Replace the latched network with one built from a fresh snapshot of
    /// the document. Carries pressures and input toggles forward by net id /
    /// component id where possible, so editing the document while playing
    /// doesn't flash everything back to atmosphere.
    func rebuild(from document: CircuitDocument) {
        let flattened = document.flattenedForSimulation()
        let next = PneumaticNetwork.build(from: flattened)
        self.flattenedDoc = flattened
        // Preserve pressures for nets that still exist; default new nets to atm.
        var nextPressures: [UUID: Double] = [:]
        let existingNetIds = Set(next.nets.map(\.id))
        for net in next.nets {
            nextPressures[net.id] = pressureByNet[net.id] ?? 1.0
        }
        pressureByNet = nextPressures
        // Drop input pressures for inputs that no longer exist; keep the rest.
        let liveInputIds = Set(next.inputs.map(\.id))
        inputPressures = inputPressures.filter { liveInputIds.contains($0.key) }
        // Same for transistors.
        let liveTransistorIds = Set(next.transistors.map(\.id))
        transistorOpenness = transistorOpenness.filter { liveTransistorIds.contains($0.key) }
        network = next
        _ = existingNetIds  // silence
    }

    /// Snap every pressure back to atmosphere and clear transistor states.
    /// Doesn't touch the input toggles — those are user intent.
    func reset() {
        pressureByNet = initialPressures(for: network)
        transistorOpenness = [:]
        simAccumulator = 0
    }

    /// Advance the simulator by `wallSeconds` of real time. Takes as many
    /// fixed-`dt` steps as fit, leaving any remainder in the accumulator.
    func advance(wallSeconds: Double) {
        guard isPlaying else { return }
        let scaledSeconds = wallSeconds * max(0, params.timeScale)
        simAccumulator += scaledSeconds
        let dt = max(params.dtSeconds, 1e-6)
        // Clamp to a small batch of steps per frame so a hitch in the UI
        // clock doesn't snowball into a multi-second catch-up burst.
        var steps = 0
        while simAccumulator >= dt && steps < 8 {
            SimulationEngine.step(
                network: network, params: params,
                pressures: &pressureByNet,
                inputs: inputPressures,
                transistorOpenness: &transistorOpenness
            )
            simAccumulator -= dt
            steps += 1
        }
        if steps == 8 {
            // Drop the rest of the backlog instead of catching up forever.
            simAccumulator = 0
        }
    }

    /// Convenience: pressure of one net, defaulting to atmosphere if the net
    /// isn't (yet) in the solved state.
    func pressure(net netId: UUID) -> Double {
        pressureByNet[netId] ?? 1.0
    }

    /// Convenience: pressure observed at a component's first fluid pin via
    /// its net id (used by probe rendering for output ports / LEDs).
    func pressure(probe: PneumaticNetwork.Probe) -> Double {
        pressure(net: probe.netId)
    }

    private func initialPressures(for network: PneumaticNetwork) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for net in network.nets { out[net.id] = 1.0 }
        for boundary in network.hardBoundaries { out[boundary.netId] = boundary.value }
        for input in network.inputs {
            out[input.netId] = inputPressures[input.id] ?? 1.0
        }
        return out
    }
}
