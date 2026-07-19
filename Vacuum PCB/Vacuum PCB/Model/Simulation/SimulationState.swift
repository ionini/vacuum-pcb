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

    /// Bumped whenever `network` / `flattenedDoc` are replaced (`rebuild`),
    /// so views can key derived-geometry caches (e.g. the flow overlay's
    /// polylines) off a cheap Int compare instead of a document compare.
    private(set) var networkRevision: Int = 0

    /// User-controlled input port pressures keyed by input component id.
    /// Default 1.0 (atmosphere) for any input not yet toggled.
    var inputPressures: [UUID: Double] = [:]

    /// Net pressure (0 = vacuum, 1 = atm) keyed by net id. Initialised to
    /// atmosphere everywhere, then refined by the integrator.
    var pressureByNet: [UUID: Double] = [:]

    /// Per-transistor 0…1 "open fraction" for UI rendering. Mirrors the
    /// conductance ramp around the gate threshold.
    var transistorOpenness: [UUID: Double] = [:]

    /// Mass-flow readout reconstructed from the latest published pressures
    /// (per-edge Q = G·ΔP plus the ranked supply budget). Refreshed on the
    /// same ~20 Hz publish cadence as `pressureByNet`, so views reading it
    /// invalidate no more often than the heatmap already does.
    var flows: FlowReport = .empty

    /// Component the user picked in the supply-budget panel; both Simulate
    /// canvases draw a highlight ring around it so a budget row can be traced
    /// to its body on the board. nil = nothing highlighted.
    var highlightedComponentId: UUID?

    /// Whether the integrator advances on each clock tick. Driven by the
    /// toolbar Play/Pause button and by the Simulate tab's appear/disappear
    /// (the tab pauses the sim on the way out and resumes it on the way in).
    ///
    /// Resuming resets the tick baseline: the clock only runs while the tab
    /// is mounted, so after a stretch on another tab `lastTick` is stale and
    /// the first tick back would otherwise integrate the whole absence as one
    /// catch-up burst.
    var isPlaying: Bool = false {
        didSet { if isPlaying && !oldValue { lastTick = nil } }
    }

    /// Sim-time accumulator so the engine takes fixed steps even when the
    /// view's clock tick is jittery. Drained on each tick. `@ObservationIgnored`
    /// because it's pure integrator bookkeeping — no view should re-render when
    /// it changes.
    @ObservationIgnored private var simAccumulator: Double = 0

    /// Monotonic count of *simulated* seconds integrated since the last
    /// `reset()`. The DSL test runner polls this to implement `wait` / `waitfor`
    /// in sim-time (so a `wait 300ms` honours the time-scale slider — a faster
    /// sim finishes the wait sooner in wall-clock). `@ObservationIgnored`: it
    /// advances every frame and nothing should re-render off it.
    @ObservationIgnored private(set) var elapsedSimSeconds: Double = 0

    /// Non-observable working copies the integrator steps into between UI
    /// publications. Seeded from the published dictionaries on first use and
    /// after `reset()` / `rebuild(...)` clear them. Keeping the fine-grained
    /// fixed steps off the observable properties is what lets us publish to
    /// SwiftUI at a throttled rate (see `advance`).
    ///
    /// Two shapes, one live at a time: the compiled path carries
    /// `workingRun` (Int-indexed arrays, zero UUID hashing per step) and the
    /// dictionaries stay nil; a network with no free nodes falls back to the
    /// legacy dictionary step and carries `workingPressures` /
    /// `workingTransistors` instead.
    @ObservationIgnored private var workingPressures: [UUID: Double]?
    @ObservationIgnored private var workingTransistors: [UUID: Double]?
    @ObservationIgnored private var workingRun: SimulationEngine.RunState?

    /// Compiled Int-indexed step tables, rebuilt on the worker whenever the
    /// network revision, subdivision flag, or hard-input toggle set moves
    /// (`SimulationEngine.compile`). Cached here between batches so a steady
    /// sim never re-hashes a UUID.
    @ObservationIgnored private var workingCompiled: SimulationEngine.CompiledNetwork?
    @ObservationIgnored private var workingCompiledRevision: Int = 0

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

    /// Serial worker that runs the engine's fixed-`dt` step batches off the
    /// main thread — same GCD pattern as the validation battery and the 3D
    /// preview rebuild. Handoff is by value both ways: a batch captures
    /// snapshots of the network / params / inputs / working dictionaries,
    /// and hands fresh dictionaries back to the main actor when it's done.
    @ObservationIgnored private let stepQueue =
        DispatchQueue(label: "com.ionini.vacuumpcb.simulate-step", qos: .userInitiated)

    /// True while a batch is out on `stepQueue`, so the pump never has two
    /// batches racing each other (the worker is stateless; ordering lives here).
    @ObservationIgnored private var stepInFlight = false

    /// Generation stamp for in-flight batches. `reset()` / `rebuild(...)` bump
    /// it, so a batch that was integrating the *old* network or pre-reset
    /// pressures is discarded on completion instead of resurrecting them.
    @ObservationIgnored private var stepEpoch = 0

    init(document: CircuitDocument) {
        let prepared = Self.prepare(document)
        self.flattenedDoc = prepared.flattened.document
        self.netIdRemap = prepared.flattened.netIdRemap
        self.assemblyBoards = prepared.boards
        self.network = PneumaticNetwork.build(from: prepared.flattened.document,
                                              netIdRemap: prepared.flattened.netIdRemap)
        self.pressureByNet = initialPressures(for: network)
        refreshFlows()
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
        let next = PneumaticNetwork.build(from: flattened.document,
                                          netIdRemap: flattened.netIdRemap)
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
        networkRevision &+= 1
        _ = existingNetIds  // silence
        // The integrator restarts from the freshly published pressures; any
        // batch still out on the step worker was integrating the old network
        // and gets discarded on completion.
        workingPressures = nil
        workingTransistors = nil
        workingRun = nil
        workingCompiled = nil
        sincePublish = 0
        stepEpoch &+= 1
        if let highlighted = highlightedComponentId,
           !flattenedDoc.logic.components.contains(where: { $0.id == highlighted }) {
            highlightedComponentId = nil
        }
        refreshFlows()
    }

    /// Snap every pressure back to atmosphere and clear transistor states.
    /// Doesn't touch the input toggles — those are user intent.
    func reset() {
        pressureByNet = initialPressures(for: network)
        transistorOpenness = [:]
        simAccumulator = 0
        elapsedSimSeconds = 0
        workingPressures = nil
        workingTransistors = nil
        // The compiled tables survive a reset (same network, same toggles) —
        // only the integrated state restarts from the fresh seed.
        workingRun = nil
        sincePublish = 0
        // Discard any in-flight step batch — it started from pre-reset state.
        stepEpoch &+= 1
        refreshFlows()
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

    /// Advance the simulator by `wallSeconds` of real time: bank the scaled
    /// sim-time and hand the integration to the background step worker.
    ///
    /// The fixed-`dt` step loop used to run inline here, on the main thread.
    /// A Time Profiler trace of the flow animation on a channel-subdivided
    /// board (2026-07-19, `sim.trace`) showed `SimulationEngine.step` owning
    /// 92% of a fully pegged main thread — physics was starving every frame
    /// the UI wanted to draw. The steps now run in batches on `stepQueue`;
    /// the main actor only banks time, hands out batches, and folds results
    /// back in on the same ~20 Hz publish cadence as before.
    func advance(wallSeconds: Double) {
        guard isPlaying else { return }
        simAccumulator += wallSeconds * max(0, params.timeScale)
        sincePublish += wallSeconds
        pumpStepBatch()
    }

    /// Hand the next fixed-`dt` batch to the step worker, if one is due and
    /// none is in flight.
    ///
    /// One batch is roughly one 60 Hz frame's worth of sim-time at the
    /// current `timeScale` (we hold `dt` small for per-step accuracy and buy
    /// speed by taking *more* steps, not bigger ones) — small enough that a
    /// fresh input toggle or slider change reaches the engine within about a
    /// frame of sim work, big enough that the queue hop is noise. Banked
    /// backlog beyond the old 4×-slack ceiling is dropped, the same policy
    /// as the old inline loop: under sustained overload (or an OS-level
    /// stall) the sim runs slower than the requested multiple instead of
    /// snowballing a catch-up burst — and, now, instead of freezing the UI.
    private func pumpStepBatch() {
        guard isPlaying, !stepInFlight else { return }
        let dt = max(params.dtSeconds, 1e-6)
        guard simAccumulator >= dt else { return }
        let nominalFrame = 1.0 / 60.0
        let targetSteps = Int((nominalFrame * max(0, params.timeScale) / dt).rounded(.up))
        let maxBacklog = min(2000, max(8, targetSteps * 4))
        let batch = min(max(1, targetSteps), Int(simAccumulator / dt))
        simAccumulator -= Double(batch) * dt
        if simAccumulator > Double(maxBacklog) * dt {
            simAccumulator = 0
        }

        stepInFlight = true
        let epoch = stepEpoch
        let net = network
        let prm = params
        let inp = inputPressures
        let revision = networkRevision
        // Compiled-path carry: hand the cached tables and run arrays to the
        // worker. `workingRun` is nilled here so the worker holds the only
        // reference and can mutate the arrays in place, copy-free; it comes
        // back (or is superseded) in `completeStepBatch`.
        let cachedCompiled = workingCompiled
        let cachedRevision = workingCompiledRevision
        let cachedRun = workingRun
        workingRun = nil
        // Seed dictionaries for whenever there's no carried run to continue
        // from (first batch, and after `reset()` / `rebuild(...)`).
        let seedPressures = workingPressures ?? pressureByNet
        let seedTransistors = workingTransistors ?? transistorOpenness
        stepQueue.async { [weak self] in
            // Reuse the compiled tables while their signature holds; any
            // move (rebuild, channel-subdivision toggle, hard input flip)
            // recompiles here, off the main thread.
            let subdivided = SimulationEngine.isSubdivided(network: net, params: prm)
            let hard = SimulationEngine.hardInputStates(network: net, inputs: inp)
            let cacheValid = cachedRevision == revision
                && cachedCompiled?.subdivided == subdivided
                && cachedCompiled?.hardInputStates == hard
            let compiled = cacheValid
                ? cachedCompiled!
                : SimulationEngine.compile(network: net, params: prm, hardInputStates: hard)
            // Base state: continue the carried run when the compile still
            // matches; rebase it through dictionaries when the compile
            // moved; else start from the seed dictionaries.
            func baseDictionaries() -> ([UUID: Double], [UUID: Double]) {
                if let c = cachedCompiled, let r = cachedRun {
                    let out = SimulationEngine.publish(compiled: c, state: r)
                    return (out.pressures, out.transistorOpenness)
                }
                return (seedPressures, seedTransistors)
            }

            if compiled.freeCount > 0 {
                var run: SimulationEngine.RunState
                if cacheValid, let carried = cachedRun {
                    run = carried
                } else {
                    let (p, t) = baseDictionaries()
                    run = SimulationEngine.makeRunState(
                        compiled: compiled, pressures: p, transistorOpenness: t)
                }
                let soft = SimulationEngine.softInputValues(network: net, inputs: inp)
                for _ in 0..<batch {
                    SimulationEngine.step(compiled: compiled, params: prm,
                                          state: &run, softInputValues: soft)
                }
                DispatchQueue.main.async {
                    self?.completeStepBatch(epoch: epoch, steps: batch, dt: dt,
                                            revision: revision,
                                            result: .compiled(compiled, run))
                }
            } else {
                // Degenerate network (every node anchored, or no nets at
                // all): the legacy dictionary step handles it.
                var (pressures, transistors) = baseDictionaries()
                for _ in 0..<batch {
                    SimulationEngine.step(
                        network: net, params: prm,
                        pressures: &pressures,
                        inputs: inp,
                        transistorOpenness: &transistors
                    )
                }
                DispatchQueue.main.async {
                    self?.completeStepBatch(epoch: epoch, steps: batch, dt: dt,
                                            revision: revision,
                                            result: .dictionaries(compiled, pressures, transistors))
                }
            }
        }
    }

    /// What one worker batch hands back: the compiled tables it stepped with
    /// (cached for the next batch) plus the integrated state — Int-indexed
    /// arrays on the compiled path, dictionaries on the degenerate path.
    private enum StepBatchResult {
        case compiled(SimulationEngine.CompiledNetwork, SimulationEngine.RunState)
        case dictionaries(SimulationEngine.CompiledNetwork, [UUID: Double], [UUID: Double])
    }

    /// Fold a finished batch back into main-actor state, publish on the
    /// throttled cadence, and chain the next batch if sim-time is still
    /// banked (so a heavy board keeps integrating flat-out without waiting
    /// for the next clock tick). A batch that raced a `reset()` /
    /// `rebuild(...)` — epoch mismatch — is discarded: it was integrating a
    /// network or state that no longer exists.
    private func completeStepBatch(
        epoch: Int, steps: Int, dt: Double, revision: Int,
        result: StepBatchResult
    ) {
        stepInFlight = false
        guard epoch == stepEpoch else { return }
        switch result {
        case let .compiled(compiled, run):
            workingCompiled = compiled
            workingCompiledRevision = revision
            workingRun = run
            workingPressures = nil
            workingTransistors = nil
        case let .dictionaries(compiled, pressures, transistors):
            workingCompiled = compiled
            workingCompiledRevision = revision
            workingRun = nil
            workingPressures = pressures
            workingTransistors = transistors
        }
        // Account the sim-time actually integrated so the test runner's
        // sim-time waits track real progress (and stall when the sim is
        // paused / starved).
        elapsedSimSeconds += Double(steps) * dt

        // Throttle the publish to SwiftUI. Reassigning the two observable
        // dictionaries re-renders the schematic canvas and re-evaluates every
        // live row in the inspector sidebar — ~20 Hz is visually smooth for a
        // heatmap and keeps that cost bounded. The array→dictionary publish
        // conversion rides the same throttle, so it never runs per step.
        if sincePublish >= publishInterval {
            sincePublish = 0
            switch result {
            case let .compiled(compiled, run):
                let out = SimulationEngine.publish(compiled: compiled, state: run)
                pressureByNet = out.pressures
                transistorOpenness = out.transistorOpenness
            case let .dictionaries(_, pressures, transistors):
                pressureByNet = pressures
                transistorOpenness = transistors
            }
            refreshFlows()
        }
        pumpStepBatch()
    }

    /// Rebuild the flow readout from the currently published pressures. Rides
    /// the publish throttle: one O(edges) pass per publish, never per step.
    private func refreshFlows() {
        flows = FlowAnalysis.report(network: network, params: params,
                                    pressures: pressureByNet, inputs: inputPressures)
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

    /// Convenience: pressure observed at a probe's solver node. `nodeId` is
    /// resolved at network build — the canonical net for ordinary probes, the
    /// mid-channel tap vertex for test points when channel subdivision is
    /// active — and the engine keeps node pressures valid in both modes.
    func pressure(probe: PneumaticNetwork.Probe) -> Double {
        pressure(net: probe.nodeId)
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
