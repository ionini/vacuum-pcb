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

    /// Maps each *unflattened* top-level net id to the canonical flattened
    /// net id that carries its pressure. Mating/subpart merges fuse nets, so
    /// a net id from the original document may no longer key `pressureByNet`;
    /// the Simulate schematic renders the unflattened topology and resolves
    /// pressure through this map. Identity for nets that weren't merged.
    private(set) var netIdRemap: [UUID: UUID] = [:]

    /// In assembly mode, the boards (parent + each subpart) laid out so their
    /// mated connectors join — what the physical canvas draws as outlines and
    /// fits to. Empty for ordinary single-board documents.
    private(set) var assemblyBoards: [AssemblyLayout.Board] = []

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
    var isPlaying: Bool = false

    /// Sim-time accumulator so the engine takes fixed steps even when the
    /// view's clock tick is jittery. Drained on each tick. `@ObservationIgnored`
    /// because it's pure integrator bookkeeping — no view should re-render when
    /// it changes.
    @ObservationIgnored private var simAccumulator: Double = 0

    /// Non-observable working copies the integrator steps into between UI
    /// publications. Seeded from the published dictionaries on first use and
    /// after `reset()` / `rebuild(...)` clear them. Keeping the fine-grained
    /// fixed steps off the observable properties is what lets us publish to
    /// SwiftUI at a throttled rate (see `advance`).
    @ObservationIgnored private var workingPressures: [UUID: Double]?
    @ObservationIgnored private var workingTransistors: [UUID: Double]?

    /// Real wall-time accumulated since we last published pressures to the
    /// observable properties. We integrate at the fine fixed `dt` for fidelity
    /// but only reassign `pressureByNet` / `transistorOpenness` — the thing that
    /// forces SwiftUI to re-render the schematic and every live readout in the
    /// inspector — once per `publishInterval`, so a 60 Hz clock doesn't drive
    /// 60 full re-renders per second.
    @ObservationIgnored private var sincePublish: Double = 0
    @ObservationIgnored private let publishInterval: Double = 1.0 / 20.0

    /// Wall-clock instant of the previous `tick()`. `@ObservationIgnored` so the
    /// clock can update it 60×/s without ever invalidating a view — the whole
    /// point of moving the delta calc here is to keep the simulator's heartbeat
    /// off SwiftUI's per-frame view-evaluation path (a `TimelineView`-driven
    /// clock leaked an observation-tracking node every frame).
    @ObservationIgnored private var lastTick: Date?

    init(document: CircuitDocument) {
        let prepared = Self.prepare(document)
        self.flattenedDoc = prepared.flattened.document
        self.netIdRemap = prepared.flattened.netIdRemap
        self.assemblyBoards = prepared.boards
        self.network = PneumaticNetwork.build(from: prepared.flattened.document)
        self.pressureByNet = initialPressures(for: network)
    }

    /// Flatten the document for the simulator, first laying out an assembly's
    /// boards so their mated connectors join (a no-op for single-board docs).
    /// The layout is a rigid transform per board, so it never changes the
    /// netlist or channel lengths — only where geometry lands in world space.
    private static func prepare(
        _ document: CircuitDocument
    ) -> (flattened: (document: CircuitDocument, netIdRemap: [UUID: UUID]),
          boards: [AssemblyLayout.Board]) {
        if let layout = document.assemblyLayout() {
            let laidOut = document.applyingAssemblyLayout(layout)
            return (laidOut.flattenedForSimulation(), layout.boards)
        }
        return (document.flattenedForSimulation(), [])
    }

    /// Replace the latched network with one built from a fresh snapshot of
    /// the document. Carries pressures and input toggles forward by net id /
    /// component id where possible, so editing the document while playing
    /// doesn't flash everything back to atmosphere.
    func rebuild(from document: CircuitDocument) {
        let prepared = Self.prepare(document)
        let flattened = prepared.flattened
        let next = PneumaticNetwork.build(from: flattened.document)
        self.flattenedDoc = flattened.document
        self.netIdRemap = flattened.netIdRemap
        self.assemblyBoards = prepared.boards
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
        // The integrator restarts from the freshly published pressures.
        workingPressures = nil
        workingTransistors = nil
        sincePublish = 0
    }

    /// Snap every pressure back to atmosphere and clear transistor states.
    /// Doesn't touch the input toggles — those are user intent.
    func reset() {
        pressureByNet = initialPressures(for: network)
        transistorOpenness = [:]
        simAccumulator = 0
        workingPressures = nil
        workingTransistors = nil
        sincePublish = 0
    }

    /// Heartbeat for the Simulate clock: advance by the real wall-time elapsed
    /// since the previous tick. The view fires this from a plain timer rather
    /// than a `TimelineView`, so no SwiftUI body is re-evaluated per frame. The
    /// first tick after (re)starting just establishes the baseline. Updating
    /// `lastTick` even while paused keeps the resume delta small.
    func tick() {
        let now = Date.now
        defer { lastTick = now }
        guard let last = lastTick else { return }
        let elapsed = max(0, now.timeIntervalSince(last))
        if elapsed > 0 { advance(wallSeconds: elapsed) }
    }

    /// Advance the simulator by `wallSeconds` of real time. Takes as many
    /// fixed-`dt` steps as fit, leaving any remainder in the accumulator.
    ///
    /// The observable dictionaries are copied to local vars for the step
    /// loop and written back once at the end — without that, every step
    /// would publish an `@Observable` change and SwiftUI would invalidate
    /// every probe, every transistor row, and both canvases up to eight
    /// times per frame.
    func advance(wallSeconds: Double) {
        guard isPlaying else { return }
        let scaledSeconds = wallSeconds * max(0, params.timeScale)
        simAccumulator += scaledSeconds
        let dt = max(params.dtSeconds, 1e-6)
        guard simAccumulator >= dt else { return }
        // Step into non-observable working copies so each fixed step doesn't
        // publish an `@Observable` change. Seed from the published state the
        // first time, and whenever `reset()` / `rebuild(...)` cleared them.
        var localPressures = workingPressures ?? pressureByNet
        var localTransistors = workingTransistors ?? transistorOpenness
        // Per-tick fixed-step budget. It scales with `timeScale` so a fast
        // clock actually advances that much sim-time — we hold `dt` small for
        // per-step accuracy and buy speed by taking *more* steps, not bigger
        // ones. The budget is what one 60 Hz frame would need at this speed,
        // times a 4× slack so ordinary clock jitter is absorbed without
        // dropping time, and it stays bounded by an absolute ceiling. Hitting
        // the ceiling drains the backlog so a real stall (e.g. the app paused
        // by the OS) can't snowball into an unrecoverable catch-up burst — the
        // sim just runs slower than the requested multiple under that load.
        let nominalFrame = 1.0 / 60.0
        let targetSteps = Int((nominalFrame * max(0, params.timeScale) / dt).rounded(.up))
        let maxSteps = min(2000, max(8, targetSteps * 4))
        var steps = 0
        while simAccumulator >= dt && steps < maxSteps {
            SimulationEngine.step(
                network: network, params: params,
                pressures: &localPressures,
                inputs: inputPressures,
                transistorOpenness: &localTransistors
            )
            simAccumulator -= dt
            steps += 1
        }
        if steps == maxSteps {
            // Drop the rest of the backlog instead of catching up forever.
            simAccumulator = 0
        }
        workingPressures = localPressures
        workingTransistors = localTransistors

        // Throttle the publish to SwiftUI. Reassigning these two observable
        // dictionaries is the single most expensive thing the simulator does —
        // it re-renders the schematic canvas and re-evaluates every live row in
        // the inspector sidebar. At the clock's 60 Hz that pegged the main
        // thread; ~20 Hz is visually smooth for a heatmap and cuts that work
        // roughly 3×.
        sincePublish += wallSeconds
        guard sincePublish >= publishInterval else { return }
        sincePublish = 0
        pressureByNet = localPressures
        transistorOpenness = localTransistors
    }

    /// Convenience: pressure of one net, defaulting to atmosphere if the net
    /// isn't (yet) in the solved state.
    func pressure(net netId: UUID) -> Double {
        pressureByNet[netId] ?? 1.0
    }

    /// Pressure of a net identified by its *unflattened* id, resolving the
    /// flatten's net merges first. Use from views that render the original
    /// document topology (the Simulate schematic); `pressure(net:)` alone
    /// would miss any net that mating/subpart merges fused into another.
    func pressure(rawNet netId: UUID) -> Double {
        pressure(net: netIdRemap[netId] ?? netId)
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
        // Pumps aren't hard boundaries any more, but the user's mental model
        // is "the rail is at vacuum the moment I hit play". Seed each pump's
        // net to the pump's deadhead pressure so the source starts primed.
        for pump in network.pumps {
            out[pump.netId] = params.pumpMaxVacuum
        }
        for input in network.inputs where !input.soft {
            // Hard inputs toggled to Vac join the pump manifold, so seed them
            // at deadhead like the pumps above instead of starting from atm.
            // Soft (bus) inputs aren't rails — they start at atmosphere with
            // every other net and settle via the integrator.
            let v = inputPressures[input.id] ?? 1.0
            out[input.netId] = v < 0.5 ? params.pumpMaxVacuum : 1.0
        }
        return out
    }
}
