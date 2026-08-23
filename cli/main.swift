import Foundation
import Euclid
import CoreText

// Headless driver for validating Vacuum PCB simulations from the command line.
//
// Reuses the app's own model: a `.vpcb` file is just JSON of a
// `CircuitDocument`, which we flatten, compile into a `PneumaticNetwork`, and
// step deterministically with `SimulationEngine.step`. We bypass
// `SimulationState` on purpose — its `advance` is wall-clock throttled for the
// live UI, whereas validation wants an exact, reproducible number of steps.

// MARK: - Pipeline

/// Load a `.vpcb` (or raw CircuitDocument JSON) file from disk.
func loadDocument(_ path: String) throws -> CircuitDocument {
    let url = URL(fileURLWithPath: path)
    let data = try Data(contentsOf: url)
    return try CircuitDocument.decoded(from: data)
}

/// Build the flattened pneumatic network for a document.
func buildNetwork(_ doc: CircuitDocument) -> PneumaticNetwork {
    Validators.buildNetwork(doc)
}

/// Seed initial net pressures (delegates to the shared `Validators` core so
/// the CLI and the in-app Validate panel stay byte-for-byte consistent).
func seedPressures(
    network: PneumaticNetwork,
    params: SimulationParameters,
    inputs: [UUID: Double]
) -> [UUID: Double] {
    Validators.seedPressures(network: network, params: params, inputs: inputs)
}

/// Run a fixed number of solver steps and return the final net pressures plus
/// per-transistor open fractions.
func simulate(
    network: PneumaticNetwork,
    params: SimulationParameters,
    inputs: [UUID: Double],
    steps: Int
) -> (pressures: [UUID: Double], transistors: [UUID: Double]) {
    var pressures = seedPressures(network: network, params: params, inputs: inputs)
    var transistors: [UUID: Double] = [:]
    // Compile once — inputs are fixed for the whole run, so the anchor set
    // never moves. Networks with no free nodes take the dictionary path.
    let compiled = SimulationEngine.compile(
        network: network, params: params,
        hardInputStates: SimulationEngine.hardInputStates(network: network, inputs: inputs))
    guard compiled.freeCount > 0 else {
        for _ in 0..<steps {
            SimulationEngine.step(
                network: network,
                params: params,
                pressures: &pressures,
                inputs: inputs,
                transistorOpenness: &transistors
            )
        }
        return (pressures, transistors)
    }
    let soft = SimulationEngine.softInputValues(network: network, inputs: inputs)
    var run = SimulationEngine.makeRunState(
        compiled: compiled, pressures: pressures, transistorOpenness: transistors)
    for _ in 0..<steps {
        SimulationEngine.step(compiled: compiled, params: params,
                              state: &run, softInputValues: soft)
    }
    let out = SimulationEngine.publish(compiled: compiled, state: run)
    return (out.pressures, out.transistorOpenness)
}

// MARK: - Sequenced (stateful) simulation

/// One step of a `--phase` sequence: the input drives to apply, and a cap on
/// how many solver steps to run before giving up on convergence.
struct Phase {
    var sets: [(label: String, value: Double)]
    var maxSteps: Int
}

/// Result of running a single phase: the effective (cumulative) input map, how
/// many steps it actually took, whether it settled, and the resulting state.
struct PhaseResult {
    var index: Int
    var sets: [(label: String, value: Double)]
    var steps: Int
    var converged: Bool
    var pressures: [UUID: Double]
    var transistors: [UUID: Double]
}

/// Run an ordered list of phases against one network, *carrying state forward*.
///
/// This is what lets us validate sequential designs (latches, registers): the
/// net pressures and transistor states from phase N feed into phase N+1, so a
/// value written in one phase is still held when a later phase reads it back —
/// exactly what a single fixed-input `simulate` run can't show, because it
/// always re-seeds from a blank (all-atmosphere) state.
///
/// Input drives are *sticky*: each phase only overrides the labels it names;
/// everything else holds its previous value. Each phase runs until it settles
/// — the largest per-net pressure movement across a 100-step window falls
/// below `epsilon` (per-step deltas lie on slow leak↔pump tails; see
/// `SimulationEngine.SettleWindow`) — or until its `maxSteps` cap, whichever
/// comes first.
func simulateSequence(
    network: PneumaticNetwork,
    params: SimulationParameters,
    phases: [Phase],
    epsilon: Double
) -> [PhaseResult] {
    var cumulative: [(label: String, value: Double)] = []
    var pressures: [UUID: Double] = [:]
    var transistors: [UUID: Double] = [:]
    var seeded = false
    var results: [PhaseResult] = []
    // Compiled tables persist across phases; a phase that flips a hard input
    // moves the anchor set, so we publish the carried state back to
    // dictionaries and recompile.
    var compiled: SimulationEngine.CompiledNetwork?
    var run: SimulationEngine.RunState?

    for (idx, phase) in phases.enumerated() {
        // Sticky merge: a phase overrides only the labels it names.
        for s in phase.sets {
            if let j = cumulative.firstIndex(where: { $0.label.lowercased() == s.label.lowercased() }) {
                cumulative[j] = s
            } else {
                cumulative.append(s)
            }
        }
        let (inputMap, unmatched) = resolveInputs(network: network, sets: cumulative)
        if !unmatched.isEmpty {
            fail("error: no input labelled \(unmatched.map { "'\($0)'" }.joined(separator: ", ")). Run `inspect` to see available labels.")
        }

        // Seed once, from the first phase's drives; thereafter carry state.
        if !seeded {
            pressures = seedPressures(network: network, params: params, inputs: inputMap)
            seeded = true
        }

        let hard = SimulationEngine.hardInputStates(network: network, inputs: inputMap)
        if compiled == nil || compiled!.hardInputStates != hard {
            if let c = compiled, let r = run {
                let out = SimulationEngine.publish(compiled: c, state: r)
                pressures = out.pressures
                transistors = out.transistorOpenness
            }
            compiled = SimulationEngine.compile(network: network, params: params,
                                                hardInputStates: hard)
            run = nil
        }

        var steps = 0
        var converged = false
        if let c = compiled, c.freeCount > 0 {
            let soft = SimulationEngine.softInputValues(network: network, inputs: inputMap)
            var r = run ?? SimulationEngine.makeRunState(
                compiled: c, pressures: pressures, transistorOpenness: transistors)
            run = nil
            var settle = SimulationEngine.SettleWindow(epsilon: epsilon, cap: phase.maxSteps)
            for _ in 0..<max(1, phase.maxSteps) {
                SimulationEngine.step(compiled: c, params: params,
                                      state: &r, softInputValues: soft)
                steps += 1
                if settle.settled(r.pressures) { converged = true; break }
            }
            let out = SimulationEngine.publish(compiled: c, state: r)
            pressures = out.pressures
            transistors = out.transistorOpenness
            run = r
        } else {
            var settle = SimulationEngine.SettleWindow(epsilon: epsilon, cap: phase.maxSteps)
            for _ in 0..<max(1, phase.maxSteps) {
                SimulationEngine.step(
                    network: network,
                    params: params,
                    pressures: &pressures,
                    inputs: inputMap,
                    transistorOpenness: &transistors
                )
                steps += 1
                if settle.settled(pressures) { converged = true; break }
            }
        }
        results.append(PhaseResult(
            index: idx, sets: phase.sets, steps: steps,
            converged: converged, pressures: pressures, transistors: transistors
        ))
    }
    return results
}

/// Friendly-named overrides for `SimulationParameters`, applied with
/// `--param NAME=VALUE`. Names match the Simulate sidebar's vocabulary.
func applyParamOverride(_ params: inout SimulationParameters, name: String, value: Double) {
    switch name.lowercased() {
    case "resistance", "resistorresistancepermm": params.resistorResistancePerMm = value
    case "flow", "pumpflowcapacity": params.pumpFlowCapacity = value
    case "pumpmax", "pumpmaxvacuum": params.pumpMaxVacuum = value
    case "onconductance", "transistoronconductance": params.transistorOnConductance = value
    case "offconductance", "transistoroffconductance": params.transistorOffConductance = value
    case "gatethreshold": params.gateThreshold = value
    case "gatehysteresis": params.gateHysteresis = value
    case "capacitance", "nodebasecapacitance": params.nodeBaseCapacitance = value
    case "channelcapacitancepermm": params.channelCapacitancePerMm = value
    case "busdrive", "busdriveconductance": params.busDriveConductance = value
    case "droop", "pumpdroopexponent": params.pumpDroopExponent = value
    case "leak", "leakconductance": params.leakConductance = value
    case "channelr", "channelresistance", "channelresistancepermm": params.channelResistancePerMm = value
    case "internalleak", "internalleakconductance": params.internalLeakConductance = value
    case "dt", "dtseconds": params.dtSeconds = value
    default:
        fail("error: unknown --param '\(name)'. Known: resistance, flow, pumpMax, onConductance, offConductance, gateThreshold, gateHysteresis, capacitance, busDrive, droop, leak, channelR, internalLeak, dt.")
    }
}

/// Parse one `--phase` argument: `LABEL=VAL,LABEL=VAL[@MAXSTEPS]`.
func parsePhase(_ raw: String, defaultMaxSteps: Int) -> Phase {
    var body = raw
    var maxSteps = defaultMaxSteps
    if let at = raw.lastIndex(of: "@") {
        body = String(raw[raw.startIndex..<at])
        let stepsStr = String(raw[raw.index(after: at)...])
        guard let n = Int(stepsStr), n > 0 else { fail("error: --phase step cap after '@' must be a positive integer") }
        maxSteps = n
    }
    var sets: [(label: String, value: Double)] = []
    for pair in body.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = parseDrive(String(parts[1]).trimmingCharacters(in: .whitespaces)) else {
            fail("error: --phase expects LABEL=VALUE pairs (e.g. --phase \"READ=vac,B0=vac@4000\")")
        }
        sets.append((String(parts[0]).trimmingCharacters(in: .whitespaces), value))
    }
    return Phase(sets: sets, maxSteps: maxSteps)
}

func reportSequence(network: PneumaticNetwork, results: [PhaseResult], probeFilter: [String], json: Bool) {
    let filter = Set(probeFilter.map { $0.lowercased() })
    let probes = network.probes.filter { filter.isEmpty || filter.contains($0.label.lowercased()) }

    if json {
        let root: [String: Any] = ["phases": results.map { r -> [String: Any] in
            [
                "phase": r.index,
                "set": r.sets.map { ["label": $0.label, "value": $0.value] },
                "steps": r.steps,
                "converged": r.converged,
                "probes": probes.map { p in ["label": p.label, "pressure": r.pressures[p.nodeId] ?? 1.0] },
            ]
        }]
        printJSON(root)
        return
    }

    for r in results {
        let drive = r.sets.map { "\($0.label)=\(fmt($0.value))" }.joined(separator: " ")
        let settle = r.converged ? "settled in \(r.steps) steps" : "did NOT settle (\(r.steps) steps cap)"
        print("── phase \(r.index): set \(drive.isEmpty ? "(hold)" : drive)  [\(settle)]")
        for probe in probes {
            let p = r.pressures[probe.nodeId] ?? 1.0
            print("    \(probe.label.isEmpty ? "<unnamed>" : probe.label)  [\(probe.kind)]  P=\(fmt(p))  \(bar(p))")
        }
    }
}

// MARK: - Input resolution

/// Translate an `--set NAME=VALUE` pair into a numeric drive. Accepts the
/// pressure convention (0 = vacuum, 1 = atmosphere) by keyword or number.
func parseDrive(_ raw: String) -> Double? {
    switch raw.lowercased() {
    case "vac", "vacuum", "0", "low": return 0.0
    case "atm", "atmosphere", "1", "high": return 1.0
    default: return Double(raw)
    }
}

/// Resolve user `--set LABEL=VALUE` arguments into an input-id → pressure map,
/// matching inputs by label (case-insensitive). Returns the map and any labels
/// that matched nothing.
func resolveInputs(
    network: PneumaticNetwork,
    sets: [(label: String, value: Double)]
) -> (map: [UUID: Double], unmatched: [String]) {
    var map: [UUID: Double] = [:]
    var unmatched: [String] = []
    for set in sets {
        let matches = network.inputs.filter { $0.label.lowercased() == set.label.lowercased() }
        if matches.isEmpty {
            unmatched.append(set.label)
        } else {
            for input in matches { map[input.id] = set.value }
        }
    }
    return (map, unmatched)
}

// MARK: - Reporting

func fmt(_ v: Double) -> String { String(format: "%.4f", v) }

func reportSimulate(
    network: PneumaticNetwork,
    pressures: [UUID: Double],
    transistors: [UUID: Double],
    steps: Int,
    showAllNets: Bool,
    probeFilter: [String],
    json: Bool
) {
    let filter = Set(probeFilter.map { $0.lowercased() })
    let probes = network.probes.filter { filter.isEmpty || filter.contains($0.label.lowercased()) }

    if json {
        var root: [String: Any] = ["steps": steps]
        root["probes"] = probes.map { probe -> [String: Any] in
            ["label": probe.label, "kind": "\(probe.kind)", "pressure": pressures[probe.nodeId] ?? 1.0]
        }
        if showAllNets {
            root["nets"] = network.nets.map { net -> [String: Any] in
                ["id": net.id.uuidString, "pressure": pressures[net.id] ?? 1.0]
            }
        }
        printJSON(root)
        return
    }

    print("steps: \(steps)")
    print("probes (\(probes.count)):")
    if probes.isEmpty {
        print("  (none)")
    }
    for probe in probes {
        let p = pressures[probe.nodeId] ?? 1.0
        print("  \(probe.label.isEmpty ? "<unnamed>" : probe.label)  [\(probe.kind)]  P=\(fmt(p))  \(bar(p))")
    }
    if showAllNets {
        print("nets (\(network.nets.count)):")
        for net in network.nets.sorted(by: { $0.label < $1.label }) {
            let p = pressures[net.id] ?? 1.0
            let name = net.label.isEmpty ? net.id.uuidString.prefix(8).description : net.label
            print("  \(name)  P=\(fmt(p))  \(bar(p))")
        }
    }
}

/// A tiny vacuum↔atm gauge so runs are skimmable at a glance.
func bar(_ p: Double) -> String {
    let clamped = max(0, min(1, p))
    let filled = Int((clamped * 10).rounded())
    return "[" + String(repeating: "#", count: 10 - filled) + String(repeating: ".", count: filled) + "]"
}

/// Supply-budget report for one settled state: what the pump is delivering,
/// how deep the rail sits, and every path drawing air into the rail, ranked.
/// The compute lives in the shared `FlowAnalysis` (same code as the Simulate
/// tab's flow overlay / supply panel).
func reportFlows(_ r: FlowReport, steps: Int, converged: Bool, showEdges: Bool,
                 network: PneumaticNetwork, json: Bool) {
    func kindLabel(_ k: FlowReport.ConsumerKind) -> String {
        switch k {
        case .resistor:     return "resistor"
        case .transistor:   return "transistor"
        case .railLeak:     return "rail-leak"
        case .internalLeak: return "wall-leak"
        }
    }
    if json {
        var pump: [String: Any] = [
            "throughput": r.pumpThroughput,
            "freeFlowMax": r.pumpFreeFlowMax,
            "utilization": r.utilization,
        ]
        if let railP = r.railPressure { pump["railPressure"] = railP }
        pump["railDriveSupply"] = r.railDriveSupply
        pump["supplyTotal"] = r.supplyTotal
        var root: [String: Any] = [
            "steps": steps, "converged": converged, "subdivided": r.subdivided,
            "pump": pump,
            "consumers": r.consumers.map { c -> [String: Any] in
                ["label": c.label, "kind": kindLabel(c.kind), "q": c.q, "detail": c.detail]
            },
            "externalDrives": r.externalDrives.map { d -> [String: Any] in
                ["label": d.label, "toward": d.towardVacuum ? "vac" : "atm", "q": d.q]
            },
        ]
        if showEdges {
            root["resistorFlows"] = network.resistors.map {
                ["label": $0.label, "q": r.flowByResistor[$0.id] ?? 0]
            }
            root["transistorFlows"] = network.transistors.map {
                ["label": $0.label, "q": r.flowByTransistor[$0.id] ?? 0]
            }
        }
        printJSON(root)
        return
    }

    print(converged ? "settled in \(steps) steps"
                    : "did NOT settle (\(steps)-step cap) — budget below is a snapshot")
    print("channel model: \(r.subdivided ? "subdivided (per-span flows real)" : "lumped (channelR=0)")")
    if let railP = r.railPressure {
        let pct = r.pumpFreeFlowMax > 0 ? Int((r.utilization * 100).rounded()) : 0
        print(String(format: "pump: Q=%.4f / ceiling %.4f  (%d%%)   rail P=%.4f  %@",
                     r.pumpThroughput, r.pumpFreeFlowMax, pct, railP, bar(railP)))
    } else {
        print("pump: none (no vacuum source and no input held at Vac)")
    }
    if abs(r.railDriveSupply) > 1e-6 {
        print(String(format: "rail also fed by external drive(s): %.4f  →  total supply %.4f",
                     r.railDriveSupply, r.supplyTotal))
    }
    if r.consumers.isEmpty {
        print("draw into rail: (none)")
    } else {
        print("draw into rail, ranked:")
        for c in r.consumers {
            let share = r.supplyTotal > 1e-12
                ? "  (\(Int((c.q / r.supplyTotal * 100).rounded()))%)" : ""
            print(String(format: "  %@ [%@]  q=%.4f%@  %@",
                         padRight(c.label.isEmpty ? "<unnamed>" : c.label, 14),
                         padRight(kindLabel(c.kind), 10), c.q, share, c.detail))
        }
        let sum = r.consumers.reduce(0) { $0 + $1.q }
        print(String(format: "  Σ draw=%.4f vs supply=%.4f  (gap = transients still charging volumes)",
                     sum, r.supplyTotal))
    }
    if !r.externalDrives.isEmpty {
        print("external drives (positive q = pulling air out of the board):")
        for d in r.externalDrives {
            print(String(format: "  %@ → %@  q=%.4f",
                         padRight(d.label, 14), d.towardVacuum ? "Vac" : "Atm", d.q))
        }
    }
    if showEdges {
        print("component through-flows (signed, pin1→pin2 / a→b):")
        for res in network.resistors {
            print(String(format: "  %@ q=%+.4f", padRight(res.label, 14),
                         r.flowByResistor[res.id] ?? 0))
        }
        for t in network.transistors {
            print(String(format: "  %@ q=%+.4f", padRight(t.label, 14),
                         r.flowByTransistor[t.id] ?? 0))
        }
    }
}

func reportInspect(_ network: PneumaticNetwork, json: Bool) {
    if json {
        let root: [String: Any] = [
            "nets": network.nets.count,
            "inputs": network.inputs.map { ["label": $0.label, "soft": $0.soft] },
            "probes": network.probes.map { ["label": $0.label, "kind": "\($0.kind)"] },
            "transistors": network.transistors.map { ["label": $0.label] },
            "resistors": network.resistors.count,
            "pumps": network.pumps.map { ["label": $0.label] },
        ]
        printJSON(root)
        return
    }
    print("nets:        \(network.nets.count)")
    print("inputs (\(network.inputs.count)):")
    for i in network.inputs { print("  \(i.label.isEmpty ? "<unnamed>" : i.label)\(i.soft ? "  (soft/bus)" : "")") }
    print("probes (\(network.probes.count)):")
    for p in network.probes { print("  \(p.label.isEmpty ? "<unnamed>" : p.label)  [\(p.kind)]") }
    print("transistors: \(network.transistors.count)")
    print("resistors:   \(network.resistors.count)")
    print("pumps:       \(network.pumps.count)")
}

/// Runs `restarts` independent minimise searches (distinct seeds) in parallel
/// across all cores and returns the best result — the smallest still-buildable
/// die. Each search is a pure `CircuitDocument -> CircuitDocument` over a value
/// type, so the only shared state is the lock-guarded parts cache; that makes
/// `concurrentPerform` safe here. The whole batch finishes in about one
/// `--seconds` budget (not N×), since the restarts run concurrently.
func runMinimize(
    _ doc: CircuitDocument, restarts: Int, baseSeed: UInt64,
    options: (UInt64) -> Minimizer.Options, verbose: Bool
) -> (doc: CircuitDocument, stats: Minimizer.Stats) {
    if restarts == 1 {
        return Minimizer.report(doc, options: options(baseSeed))
    }
    var results = [(doc: CircuitDocument, stats: Minimizer.Stats)?](repeating: nil, count: restarts)
    let lock = NSLock()
    DispatchQueue.concurrentPerform(iterations: restarts) { k in
        let r = Minimizer.report(doc, options: options(baseSeed &+ UInt64(k)))
        lock.lock(); results[k] = r; lock.unlock()
    }
    let runs = results.compactMap { $0 }
    func dieArea(_ d: CircuitDocument) -> Double {
        d.physical.boardOutline.size.width * d.physical.boardOutline.size.height
    }
    if verbose {
        for (k, r) in runs.enumerated() {
            print(String(format: "  restart %d (seed %llu): %@", k, baseSeed &+ UInt64(k), r.stats.summary))
        }
    }
    // Best = adopted, smallest die, then least wirelength; fall back to any run
    // (they all return the unchanged input when nothing beat it).
    let best = runs.min { a, b in
        if a.stats.adopted != b.stats.adopted { return a.stats.adopted }
        let da = dieArea(a.doc), db = dieArea(b.doc)
        if abs(da - db) > 1e-6 { return da < db }
        return a.stats.wirelengthAfter < b.stats.wirelengthAfter
    }
    return best ?? Minimizer.report(doc, options: options(baseSeed))
}

func reportMinimize(_ before: CircuitDocument, _ after: CircuitDocument, stats: Minimizer.Stats, json: Bool) {
    let beforeDie = before.physical.boardOutline.size.width * before.physical.boardOutline.size.height
    let afterDie = after.physical.boardOutline.size.width * after.physical.boardOutline.size.height
    if json {
        let root: [String: Any] = [
            "adopted": stats.adopted,
            "iterations": stats.iterations,
            "accepted": stats.accepted,
            "rejected": stats.rejected,
            "elapsed": stats.elapsed,
            "dieBefore": beforeDie,
            "dieAfter": afterDie,
            "diePct": beforeDie > 0 ? (1 - afterDie / beforeDie) * 100 : 0,
            "outlineBefore": ["w": stats.outlineBefore.size.width, "h": stats.outlineBefore.size.height],
            "outlineAfter": ["w": stats.outlineAfter.size.width, "h": stats.outlineAfter.size.height],
            "wireBefore": stats.wirelengthBefore,
            "wireAfter": stats.wirelengthAfter,
            "drcBefore": stats.baselineIssues,
            "drcAfter": stats.finalIssues,
            "viasBefore": stats.crossSiliconeViasBefore,
            "viasAfter": stats.crossSiliconeViasAfter,
            "orientationFlips": stats.orientationFlips,
        ]
        printJSON(root)
        return
    }
    print(stats.summary)
    let saved = beforeDie > 0 ? (1 - afterDie / beforeDie) * 100 : 0
    print(String(format: "die: %.0f×%.0f → %.0f×%.0f mm²  (%.1f%% area %@)",
                 stats.outlineBefore.size.width, stats.outlineBefore.size.height,
                 stats.outlineAfter.size.width, stats.outlineAfter.size.height,
                 saved, stats.adopted ? "saved" : "— not adopted"))
    print(String(format: "vias: %d → %d  (%d transistor flip%@)",
                 stats.crossSiliconeViasBefore, stats.crossSiliconeViasAfter,
                 stats.orientationFlips, stats.orientationFlips == 1 ? "" : "s"))
}

/// Collapse a DRC issue list into a "kind: count" histogram for skimmable
/// router-quality reporting.
func drcHistogram(_ issues: [DRC.Issue]) -> [(String, Int)] {
    var counts: [String: Int] = [:]
    for issue in issues {
        let key: String
        switch issue.kind {
        case .unplacedPin: key = "unplacedPin"
        case .noRouteDrawn: key = "noRouteDrawn"
        case .disconnectedPin: key = "disconnectedPin"
        case .orphanVia: key = "orphanVia"
        case .channelClearance: key = "channelClearance"
        case .crossNetMerge: key = "crossNetMerge"
        case .thinWall(let n, _, _, _, _): key = "thinWall(\(n.rawValue))"
        case .matingIncompatible: key = "matingIncompatible"
        case .matingDoubleBooked: key = "matingDoubleBooked"
        case .screwClearance(_, let n, _, _): key = "screwClearance(\(n.rawValue))"
        case .viaSpacing: key = "viaSpacing"
        case .viaPad: key = "viaPad"
        case .stencilHole: key = "stencilHole"
        case .portBoreClearance(_, _, let n, _, _, _, _, _, _): key = "portBoreClearance(\(n.rawValue))"
        case .testPointClearance(_, _, let n, _, _, _, _): key = "testPointClearance(\(n.rawValue))"
        case .subpartWall(let n, _, _, _, _, _): key = "subpartWall(\(n.rawValue))"
        case .subpartPinDrift: key = "subpartPinDrift"
        case .sealedCavity: key = "sealedCavity"
        }
        counts[key, default: 0] += 1
    }
    return counts.sorted { $0.value > $1.value }
}

/// Strip every route and re-route from scratch with the auto-router. Used to
/// measure router quality independent of the placement search.
func rerouteFromScratch(_ doc: CircuitDocument) -> CircuitDocument {
    var out = doc
    out.physical.routes.removeAll()
    for entry in AutoRouter.planNegotiated(out) {
        if let i = out.physical.routes.firstIndex(where: { $0.netId == entry.netId }) {
            out.physical.routes[i].segments.append(entry.segment)
        } else {
            out.physical.routes.append(Route(netId: entry.netId, segments: [entry.segment]))
        }
    }
    return out
}

func reportReroute(_ before: CircuitDocument, _ after: CircuitDocument, json: Bool) {
    let b = DRC.check(before), a = DRC.check(after)
    if json {
        printJSON([
            "drcBefore": b.count, "drcAfter": a.count,
            "histBefore": Dictionary(uniqueKeysWithValues: drcHistogram(b)),
            "histAfter": Dictionary(uniqueKeysWithValues: drcHistogram(a)),
        ])
        return
    }
    print("DRC before reroute: \(b.count)")
    for (k, v) in drcHistogram(b) { print("  \(k): \(v)") }
    print("DRC after reroute:  \(a.count)")
    for (k, v) in drcHistogram(a) { print("  \(k): \(v)") }
    for issue in a.prefix(40) { print("    • \(issue.summary)") }
}

/// Replace non-finite Doubles/Floats (NaN, ±Inf) with null so the JSON writer
/// can't abort. The solver legitimately emits NaN at near-singular operating
/// points (e.g. very low leak combined with low resistance); `JSONSerialization`
/// throws an *uncatchable* ObjC exception on those (so `try?` doesn't help) —
/// we have to scrub them before handing the object over.
func jsonSanitized(_ obj: Any) -> Any {
    switch obj {
    case let d as Double: return d.isFinite ? d : NSNull()
    case let f as Float:  return f.isFinite ? f : NSNull()
    case let a as [Any]:  return a.map(jsonSanitized)
    case let m as [String: Any]: return m.mapValues(jsonSanitized)
    default: return obj
    }
}

func printJSON(_ obj: Any) {
    let safe = jsonSanitized(obj)
    guard JSONSerialization.isValidJSONObject(safe),
          let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys]),
          let str = String(data: data, encoding: .utf8) else {
        print("{}")
        return
    }
    print(str)
}

// MARK: - Validation reporting (compute lives in the shared `Validators`)

func reportMesh(_ r: Validators.MeshResult, json: Bool) {
    if json {
        printJSON([
            "pass": r.pass,
            "bodies": r.bodies.map { b -> [String: Any] in
                ["body": b.name, "empty": b.empty, "watertight": b.watertight,
                 "signedVolume": b.signedVolume, "polygons": b.polygons, "pass": b.pass]
            },
        ])
        return
    }
    for b in r.bodies {
        if b.empty {
            print("  \(b.name): EMPTY" + (b.required ? "  ✗ required body missing" : "  (ok — disabled)"))
            continue
        }
        print(String(format: "  %@: %@  watertight=%@  vol=%.1f mm³  polys=%d  bbox=%.1f×%.1f×%.1f mm",
                     b.pass ? "✓" : "✗", b.name, b.watertight ? "yes" : "NO",
                     b.signedVolume, b.polygons, b.size.x, b.size.y, b.size.z))
        if !b.watertight { print("     ✗ not watertight after stitching — a slicer will reject this") }
        if b.signedVolume <= 0 { print("     ✗ non-positive volume — inside-out or degenerate CSG") }
    }
    print(r.pass ? "MESH: PASS" : "MESH: FAIL")
}

// MARK: - STL export

/// The solids the STL export ships, in the GUI's order, with empty bodies
/// dropped. Mirrors `STLExportDocument` / DocumentView's Bambu path:
/// top plate, bottom plate, stencil, one gasket stencil per `.bottomExtend`
/// connector (`stencil_<label>`), mold frame.
func exportBodies(_ out: PlateBuilder.Output) -> [(name: String, mesh: Mesh)] {
    ([("topPlate", out.topPlate), ("bottomPlate", out.bottomPlate),
      ("stencil", out.stencil)]
     + out.connectorStencils.map { ("stencil_\($0.name)", $0.mesh) }
     + [("moldFrame", out.moldFrame)])
        .filter { !$0.1.isEmpty }
        .map { (name: $0.0, mesh: $0.1) }
}

/// Resolve a `--body` selector to one of `exportBodies`' names. Accepts the
/// canonical camelCase name plus the obvious short forms, case-insensitively.
/// Connector gasket stencils aren't fixed names — they're matched against the
/// built body list at the call site instead.
func canonicalBodyName(_ raw: String) -> String? {
    switch raw.lowercased() {
    case "topplate", "top": return "topPlate"
    case "bottomplate", "bottom": return "bottomPlate"
    case "stencil": return "stencil"
    case "moldframe", "mold", "frame": return "moldFrame"
    default: return nil
    }
}

/// Union a raised text label onto a body's upper face, centred.
///
/// For sweep plates: many copies of one coupon differ only by a parameter, and
/// identical parts are indistinguishable the moment they leave the print bed, so
/// the label has to be part of the geometry. Glyphs are sunk `sink` mm into the
/// face so the union has real overlap to stitch rather than a coplanar kiss.
/// Uses the same CoreText path as `PlateBuilder.testPointLabelMesh`.
func embossLabel(on mesh: Mesh, text: String, size: Double, emboss: Double) -> Mesh {
    let sink = 0.02
    let font = CTFontCreateWithName("Helvetica" as CFString, size, nil)
    // `Mesh.text` centres its extrusion on z = 0 rather than extruding upward,
    // so the glyphs are aligned by their own measured bounds below instead of
    // by an assumed convention.
    let glyphs = Mesh.text(text, font: font, depth: emboss + sink, detail: 2)
    guard !glyphs.polygons.isEmpty else {
        fail("error: --label \"\(text)\" produced no printable glyphs")
    }
    let b = mesh.bounds
    let g = glyphs.bounds
    if g.max.x - g.min.x > b.max.x - b.min.x || g.max.y - g.min.y > b.max.y - b.min.y {
        fail(String(format: "error: the label is %.1f×%.1f mm but the face is only %.1f×%.1f mm "
                    + "— shorten it or drop --label-size",
                    g.max.x - g.min.x, g.max.y - g.min.y,
                    b.max.x - b.min.x, b.max.y - b.min.y))
    }
    // Centre on the face in XY; in Z, seat the glyph bottoms `sink` mm below the
    // face so the union has real overlap to stitch, leaving `emboss` mm proud.
    let placed = glyphs.translated(by: Vector(
        (b.min.x + b.max.x) / 2 - (g.min.x + g.max.x) / 2,
        (b.min.y + b.max.y) / 2 - (g.min.y + g.max.y) / 2,
        (b.max.z - sink) - g.min.z))
    return mesh.union(placed)
}

/// A body prints cleanly only if it stitched watertight with a positive
/// (right-side-out) volume — the same judgement `Validators.mesh` applies.
func bodyPasses(_ m: Mesh) -> Bool { m.isWatertight && m.signedVolume > 0 }

func reportExport(dest: String, bodies: [(name: String, mesh: Mesh)], bytes: Int, json: Bool) {
    if json {
        printJSON([
            "out": dest,
            "bytes": bytes,
            "bodies": bodies.map { b -> [String: Any] in
                let s = b.mesh.bounds
                return ["body": b.name, "watertight": b.mesh.isWatertight,
                        "signedVolume": b.mesh.signedVolume, "polygons": b.mesh.polygons.count,
                        "size": ["x": s.max.x - s.min.x, "y": s.max.y - s.min.y, "z": s.max.z - s.min.z],
                        "pass": bodyPasses(b.mesh)]
            },
        ])
        return
    }
    print("wrote \(dest)  (\(bytes) bytes, \(bodies.count) solid\(bodies.count == 1 ? "" : "s"))")
    for b in bodies {
        let bb = b.mesh.bounds
        print(String(format: "  %@ %@  watertight=%@  vol=%.1f mm³  polys=%d  bbox=%.1f×%.1f×%.1f mm",
                     bodyPasses(b.mesh) ? "✓" : "✗", b.name,
                     b.mesh.isWatertight ? "yes" : "NO",
                     b.mesh.signedVolume, b.mesh.polygons.count,
                     bb.max.x - bb.min.x, bb.max.y - bb.min.y, bb.max.z - bb.min.z))
    }
    if !bodies.allSatisfy({ bodyPasses($0.mesh) }) {
        print("⚠ one or more solids are not watertight — a slicer may reject this STL (the file was still written)")
    }
}

func reportBambuExport(_ r: BambuExport.WriteResult, dir: URL,
                       margins: PlateBuilder.ModifierMargins, json: Bool) {
    func size(_ b: Bounds) -> [String: Double] { ["x": b.max.x - b.min.x, "y": b.max.y - b.min.y, "z": b.max.z - b.min.z] }
    if json {
        printJSON([
            "dir": dir.path,
            "units": "millimeters",
            "modifierMarginXY": margins.xy, "modifierMarginZ": margins.z,
            "objects": r.objects.map { o -> [String: Any] in
                var entry: [String: Any] = [
                    "name": o.plate.rawValue,
                    "model": ["file": o.modelURL.lastPathComponent,
                              "polygons": o.modelMesh.polygons.count,
                              "size": size(o.modelMesh.bounds)],
                ]
                if let url = o.modifierURL, let mesh = o.modifierMesh {
                    entry["modifier"] = ["file": url.lastPathComponent,
                                         "polygons": mesh.polygons.count,
                                         "size": size(mesh.bounds)]
                }
                return entry
            },
            "manifest": r.manifestURL?.lastPathComponent as Any,
        ])
        return
    }
    print("wrote Bambu Studio export → \(dir.path)")
    for o in r.objects {
        let name = o.plate.rawValue.padding(toLength: 6, withPad: " ", startingAt: 0)
        let mb = o.modelMesh.bounds
        print(String(format: "  %@ model    %@  polys=%d  bbox=%.1f×%.1f×%.1f mm  (laid out for print)",
                     name, o.modelURL.lastPathComponent, o.modelMesh.polygons.count,
                     mb.max.x - mb.min.x, mb.max.y - mb.min.y, mb.max.z - mb.min.z))
        if let url = o.modifierURL, let mesh = o.modifierMesh {
            let xb = mesh.bounds
            print(String(format: "  %@ modifier %@  polys=%d  bbox=%.1f×%.1f×%.1f mm  (margins xy=%g z=%g mm)",
                         name, url.lastPathComponent, mesh.polygons.count,
                         xb.max.x - xb.min.x, xb.max.y - xb.min.y, xb.max.z - xb.min.z,
                         margins.xy, margins.z))
        } else {
            print("  \(name) ⚠ no print-critical pneumatic features on this plate — no modifier written")
        }
    }
    for aux in r.auxiliaryURLs { print("  body   \(aux.lastPathComponent)  (separate object, no modifier)") }
    if let manifest = r.manifestURL { print("  manifest \(manifest.lastPathComponent)") }
    if let first = r.objects.first(where: { $0.modifierURL != nil }), let firstModifier = first.modifierURL {
        print("Next, once per plate: select \(first.modelURL.lastPathComponent) + \(firstModifier.lastPathComponent) in Bambu Studio, load as ONE object, set the _modifier part to Modifier — then repeat for the other plate's pair. Each plate stays its own object, so the plates can be arranged and printed separately. Never select all four files at once (they'd merge into one inseparable object) and never Split.")
    } else {
        print("⚠ every modifier is empty — this board has no print-critical pneumatic features to envelope")
    }
}

func reportSweep(_ sw: Validators.SweepResult, json: Bool) {
    if json {
        printJSON([
            "inputs": sw.inputLabels, "probes": sw.probeLabels,
            "combos": sw.rows.count,
            "converged": sw.rows.filter(\.converged).count,
            "allConverged": sw.allConverged,
            "rows": sw.rows.map { ["in": $0.bits, "probes": $0.probes, "converged": $0.converged, "steps": $0.steps] },
        ])
        return
    }
    if let tooMany = sw.tooManyCombos {
        print("Exhaustive sweep skipped: \(tooMany) input combinations exceed --max-combos.")
        print("SWEEP: FAIL (raise --max-combos to brute-force it)")
        return
    }
    let conv = sw.rows.filter(\.converged).count
    print("Exhaustive sweep: \(sw.rows.count) input combinations")
    print("  inputs:  \(sw.inputLabels.joined(separator: " "))")
    if !sw.heldLabels.isEmpty { print("  held:    \(sw.heldLabels.joined(separator: " "))") }
    print("  probes:  \(sw.probeLabels.joined(separator: " "))")
    print("  converged: \(conv)/\(sw.rows.count)")
    if conv != sw.rows.count {
        print("  ✗ NON-CONVERGING combinations (oscillating / metastable):")
        for r in sw.rows where !r.converged {
            print("      in=[\(r.bits.map(String.init).joined())]  (hit \(r.steps)-step cap)")
        }
    }
    let cap = 64
    print("  truth table (probe pressure, 0=vac 1=atm):")
    for (idx, r) in sw.rows.enumerated() {
        if idx == cap { print("      … \(sw.rows.count - cap) more rows (use --json for all)"); break }
        let inStr = r.bits.map(String.init).joined()
        let outStr = r.probes.map { String(format: "%.2f", $0) }.joined(separator: " ")
        print("      [\(inStr)] → \(outStr)\(r.converged ? "" : "  ✗osc")")
    }
    print(sw.allConverged ? "SWEEP: PASS (all combinations settle)"
                          : "SWEEP: FAIL (some combinations never settle)")
}

func reportMargins(_ r: Validators.MarginResult, json: Bool) {
    if json {
        printJSON([
            "tol": r.tol, "corners": r.corners, "pass": r.pass,
            "failures": r.failures.map { ["corner": $0.label, "detail": $0.detail] },
        ])
        return
    }
    print("Margin sweep: ±\(Int(r.tol * 100))% on \(r.keys.joined(separator: ", ")) "
        + "(\(r.corners) corners × \(r.inputCombos) input combos)")
    if r.failures.isEmpty {
        print("MARGINS: PASS (logic levels stable + converges across ±\(Int(r.tol * 100))%)")
    } else {
        print("MARGINS: FAIL")
        for f in r.failures.prefix(40) { print("  ✗ [\(f.label)]: \(f.detail)") }
    }
}

func reportStaleness(_ r: Validators.StalenessResult, libDir: String?, json: Bool) {
    if json {
        printJSON(["pass": r.pass, "problems": r.hardProblems, "stale": r.stale, "info": r.info])
        return
    }
    for p in r.hardProblems { print("  ✗ \(p)") }
    for s in r.stale { print("  ✗ \(s)") }
    for n in r.info { print("  · \(n)") }
    if libDir == nil { print("  (pass --lib DIR to also check the embedded snapshots against the on-disk library)") }
    print(r.pass ? "STALENESS: PASS (self-contained\(libDir == nil ? "" : " + current"))" : "STALENESS: FAIL")
}

// MARK: - Continuity checklist
//
// A pneumatic "buzz-out" list: for each net, every physical opening you can
// press a vacuum tube against. Probing one point should pull every other point
// on the SAME net to a hard vacuum and leave every point on every OTHER net
// dead — the physical proof that the printed board matches the designed
// netlist. This catches the fault class the simulator can't see: a channel
// that didn't print through, two channels that fused, or a via that didn't
// actually connect its layers.
//
// Top-level only, exactly like `check`: subpart internals and post-mating net
// merges aren't descended into (open each subpart's own .vpcb to probe it).

/// One physical opening on the board, grouped under its net.
enum ProbePoint {
    /// A placed component pin (gate / source-drain / port bore / resistor end /
    /// connector tube / subpart boundary pin).
    case pin(ref: String, feature: String, layer: Layer, pos: Point)
    /// A drilled via, with the set of layers that meet at it.
    case via(pos: Point, layers: Set<Layer>)
    /// A pin whose component isn't placed — can't be located on the board.
    case unplaced(ref: String, feature: String)
}

// `continuityFeature(_:pinKey:)` and the physical-volume model
// (`Volume`/`VolumeHole`/`physicalVolumes`) live in the shared Model layer
// (`Model/PhysicalVolumes.swift`) so the GUI's 3D volume highlighter and this
// CLI stay in lockstep.

/// Build the per-net probe-point listing for a document. Walks the top-level
/// logic nets (subparts aren't descended into) and resolves each pin to its
/// world position + layer, then adds every via on the net.
func continuityChecklist(_ doc: CircuitDocument) -> [(net: Net, points: [ProbePoint])] {
    let m = doc.manufacturing
    let snaps = doc.librarySnapshots
    let compById = Dictionary(doc.logic.components.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    let placeById = Dictionary(doc.physical.placements.map { ($0.componentId, $0) }, uniquingKeysWith: { a, _ in a })

    var result: [(net: Net, points: [ProbePoint])] = []
    for net in doc.logic.nets {
        var points: [ProbePoint] = []
        for pinRef in net.pins {
            guard let comp = compById[pinRef.componentId] else { continue }
            let feature = continuityFeature(comp, pinKey: pinRef.pinKey)
            // Use the friendliest available pin name: connectors carry a
            // user-given name, subpart pins a library boundary-pin label
            // (the raw key is a UUID), everything else the bare key.
            let pinName: String
            switch comp.kind {
            case .connector: pinName = comp.connectorPinName(pinRef.pinKey)
            case .subpart:   pinName = comp.subpartBoundaryPin(key: pinRef.pinKey, snapshots: snaps)?.label ?? pinRef.pinKey
            default:         pinName = pinRef.pinKey
            }
            let ref = "\(comp.label).\(pinName)"
            guard let place = placeById[pinRef.componentId] else {
                points.append(.unplaced(ref: ref, feature: feature))
                continue
            }
            guard let fpPin = comp.footprint(m, snapshots: snaps).pin(pinRef.pinKey) else { continue }
            points.append(.pin(
                ref: ref, feature: feature,
                layer: place.resolvedLayer(of: fpPin, on: comp),
                pos: place.worldPosition(of: fpPin)
            ))
        }
        for group in doc.physical.viaLayerGroups(netId: net.id) {
            points.append(.via(pos: group.position, layers: group.layers))
        }
        result.append((net: net, points: points))
    }
    return result.sorted { $0.net.label < $1.net.label }
}

// MARK: - Physical volumes (compute lives in Model/PhysicalVolumes.swift)

func reportVolumes(_ doc: CircuitDocument, volumes: [Volume], json: Bool) {
    let outline = doc.physical.boardOutline
    let top = volumes.filter { $0.plate == .top }
    let bottom = volumes.filter { $0.plate == .bottom }

    if json {
        func dump(_ vs: [Volume]) -> [[String: Any]] {
            vs.map { v in
                [
                    "id": v.id,
                    "plate": v.plate.rawValue,
                    "net": v.netLabel,
                    "holes": v.holes.map { h -> [String: Any] in
                        ["ref": h.ref, "feature": h.feature, "layer": h.layer.uiLabel,
                         "bridge": h.isBridge, "x": h.pos.x, "y": h.pos.y]
                    },
                ]
            }
        }
        printJSON([
            "file": path,
            "boardOutline": ["minX": outline.minX, "minY": outline.minY,
                             "maxX": outline.maxX, "maxY": outline.maxY],
            "topPlate": dump(top),
            "bottomPlate": dump(bottom),
        ])
        return
    }

    print("physical volume checklist — test each plate on its own, before assembly")
    print(String(format: "board: (%.2f, %.2f) … (%.2f, %.2f) mm  — coordinates are board mm (GUI physical view)",
                 outline.minX, outline.minY, outline.maxX, outline.maxY))
    print("")
    print("Each VOLUME is one sealed cavity in one plate. Plug every hole but one,")
    print("press vacuum on the last → a perfect vacuum means that cavity is fully")
    print("connected and leak-free. \"via → … plate\" holes join the other plate through")
    print("the silicone once assembled — leave those for the assembled-board test.")
    print("")

    var bridges = 0
    func section(_ vs: [Volume], _ title: String) {
        print("══ \(title) — \(vs.count) volume\(vs.count == 1 ? "" : "s") ══")
        if vs.isEmpty { print("  (none)"); print(""); return }
        for v in vs {
            print("  \(v.id)  [net \(v.netLabel)]  \(v.holes.count) hole\(v.holes.count == 1 ? "" : "s")")
            for h in v.holes {
                if h.isBridge { bridges += 1 }
                let coord = String(format: "(%.2f, %.2f)", h.pos.x, h.pos.y)
                print("      • \(padRight(h.ref, 20)) \(padRight(h.feature, 26)) \(padRight(h.layer.uiLabel, 4)) \(coord)")
            }
        }
        print("")
    }
    section(top, "TOP PLATE")
    section(bottom, "BOTTOM PLATE")

    print("summary: \(volumes.count) volume\(volumes.count == 1 ? "" : "s") (\(top.count) top, \(bottom.count) bottom), \(bridges) through-hole bridge\(bridges == 1 ? "" : "s")")
    print("note: a volume whose holes won't all pull together points to a channel that")
    print("      didn't print through; a volume that won't hold vacuum has a leak or a")
    print("      hole you didn't expect. Both are invisible to the simulator.")
}

func reportCollisions(_ r: Validators.CollisionResult, json: Bool) {
    if json {
        printJSON([
            "file": path,
            "volumes": r.volumeCount,
            "pass": r.pass,
            "collisions": r.hits.map { h -> [String: Any] in
                ["a": h.a, "b": h.b, "netA": h.netA, "netB": h.netB, "plate": h.plate.rawValue,
                 "layerA": h.layerA.uiLabel, "layerB": h.layerB.uiLabel,
                 "x": h.at.x, "y": h.at.y, "overlap": h.overlap]
            },
        ])
        return
    }
    print("volume collisions: \(r.volumeCount) cavities checked")
    if r.hits.isEmpty {
        print("COLLISIONS: PASS (no two separate volumes overlap)")
        return
    }
    print("\(r.hits.count) unintended overlap\(r.hits.count == 1 ? "" : "s") — volumes that should be isolated touch in the printed geometry:")
    for h in r.hits.prefix(80) {
        print(String(format: "  ✗ %@ ↔ %@  (nets %@ ↔ %@)  on %@ at (%.2f, %.2f)  %.2f mm overlap",
                     h.a, h.b, h.netA, h.netB, h.layerA.uiLabel, h.at.x, h.at.y, h.overlap))
    }
    print("COLLISIONS: FAIL (a 2D-DRC-invisible short — two distinct nets fused)")
}

/// Left-pad `s` to `width` with spaces so columns line up (%@ width flags are
/// unreliable for Swift strings, so we pad by hand).
func padRight(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
}

/// "T0↔B0" / "T0,T1" — the layers a via touches, sorted for stable output.
func continuityViaLabel(_ layers: Set<Layer>) -> String {
    let sorted = layers.map { $0.uiLabel }.sorted()
    // Spans both plates → a real through-hole (joined with ↔); same-plate
    // depth pairs are internal (joined with ,).
    let spansPlates = Set(layers.map { $0.plate }).count >= 2
    return sorted.joined(separator: spansPlates ? "↔" : ",")
}

func reportContinuity(_ doc: CircuitDocument, nets: [(net: Net, points: [ProbePoint])], json: Bool, flattened: Bool) {
    let outline = doc.physical.boardOutline
    let subpartCount = doc.logic.components.filter { $0.kind == .subpart }.count

    if json {
        let netsJSON = nets.map { entry -> [String: Any] in
            [
                "net": entry.net.label,
                "id": entry.net.id.uuidString,
                "points": entry.points.map { p -> [String: Any] in
                    switch p {
                    case let .pin(ref, feature, layer, pos):
                        return ["type": "pin", "ref": ref, "feature": feature,
                                "layer": layer.uiLabel, "plate": layer.plate.rawValue,
                                "x": pos.x, "y": pos.y]
                    case let .via(pos, layers):
                        let plates = Set(layers.map { $0.plate })
                        return ["type": "via",
                                "layers": layers.map { $0.uiLabel }.sorted(),
                                "throughHole": plates.count >= 2,
                                "orphan": layers.count < 2,
                                "x": pos.x, "y": pos.y]
                    case let .unplaced(ref, feature):
                        return ["type": "unplaced", "ref": ref, "feature": feature]
                    }
                },
            ]
        }
        printJSON([
            "file": path,
            "scope": flattened ? "full-board" : "top-level",
            "boardOutline": ["minX": outline.minX, "minY": outline.minY,
                             "maxX": outline.maxX, "maxY": outline.maxY],
            "nets": netsJSON,
        ])
        return
    }

    print("pneumatic continuity checklist")
    if flattened {
        print("scope: FULL BOARD — every embedded subpart's internal holes expanded into")
        print("       board coordinates (labels are prefixed, e.g. U6.Q1.gate)")
    } else {
        print("scope: top-level routes only — subpart internals & post-mating merges not")
        print("       included (re-run with --flatten to expand them)")
    }
    print(String(format: "board: (%.2f, %.2f) … (%.2f, %.2f) mm  — coordinates are board mm (GUI physical view)",
                 outline.minX, outline.minY, outline.maxX, outline.maxY))
    print("")

    var totalPoints = 0
    var orphanNets = 0
    var emptyNets = 0
    for entry in nets {
        let count = entry.points.count
        totalPoints += count
        if count == 0 {
            emptyNets += 1
            print("NET \"\(entry.net.label)\"  — no physical probe points, nothing to test")
            print("")
            continue
        }
        print("NET \"\(entry.net.label)\"  (\(count) probe point\(count == 1 ? "" : "s"))")
        print("  apply vacuum at any one point; every point on THIS net should pull a hard")
        print("  vacuum, and no point on any OTHER net should move:")
        var orphanHere = false
        for p in entry.points {
            switch p {
            case let .pin(ref, feature, layer, pos):
                let coord = String(format: "(%.2f, %.2f)", pos.x, pos.y)
                print("    • \(padRight(ref, 16)) \(padRight(feature, 26)) \(padRight(layer.uiLabel, 7)) \(coord)")
            case let .via(pos, layers):
                let coord = String(format: "(%.2f, %.2f)", pos.x, pos.y)
                let label = continuityViaLabel(layers)
                if layers.count < 2 {
                    orphanHere = true
                    print("    • \(padRight("via", 16)) \(padRight("via — BROKEN", 26)) \(padRight(label, 7)) \(coord)  ⚠ ORPHAN: touches one layer only, will NOT connect (DRC: orphanVia)")
                } else if Set(layers.map { $0.plate }).count >= 2 {
                    print("    • \(padRight("via", 16)) \(padRight("through-hole (either face)", 26)) \(padRight(label, 7)) \(coord)")
                } else {
                    print("    • \(padRight("via", 16)) \(padRight("internal via (buried)", 26)) \(padRight(label, 7)) \(coord)")
                }
            case let .unplaced(ref, feature):
                print("    • \(padRight(ref, 16)) \(padRight(feature, 26)) \(padRight("—", 7)) ⚠ UNPLACED — no board position")
            }
        }
        if orphanHere { orphanNets += 1 }
        print("")
    }

    print("summary: \(nets.count) net\(nets.count == 1 ? "" : "s"), \(totalPoints) probe point\(totalPoints == 1 ? "" : "s")")
    if emptyNets > 0 {
        print("· \(emptyNets) net\(emptyNets == 1 ? " has" : "s have") no physical probe points")
    }
    if orphanNets > 0 {
        print("⚠ \(orphanNets) net\(orphanNets == 1 ? "" : "s") contain an orphan via (a via that won't actually connect its layers) — run `check` for DRC detail")
    }
    if !flattened && subpartCount > 0 {
        print("⚠ this board has \(subpartCount) subpart instance\(subpartCount == 1 ? "" : "s") whose internal holes are NOT listed above.")
        print("  Embedded subparts print into this same board — re-run with --flatten to include them.")
    }
}

// MARK: - Argument parsing

let usage = """
vacuum-cli — headless validation for Vacuum PCB circuits

USAGE:
  vacuum-cli inspect <file.vpcb> [--json]
      List the simulatable inputs, probes, transistors and nets.

  vacuum-cli simulate <file.vpcb> [options]
      Run the solver and print probe pressures (0 = vacuum, 1 = atmosphere).

  vacuum-cli flows <file.vpcb> [options]
      Solve to a settled state, then report the supply budget: pump throughput
      vs its free-flow ceiling, rail depth, and every path drawing air into
      the rail, ranked worst-first (a pull-up fighting an open vent path is
      continuous static draw; one holding an isolated node is just the leak
      floor). Accepts the same --set / --phase / --param / --steps / --epsilon
      options as simulate — with --phase the budget describes the final
      phase's settled state (e.g. a register in hold). --all-nets adds every
      resistor's and transistor's signed through-flow.

  vacuum-cli minimize <file.vpcb> [options]
      Compact a placed-and-routed board and report the area saved.

  vacuum-cli reroute <file.vpcb> [--out PATH] [--json]
      Clear all routes, re-route from scratch, report the DRC breakdown.
      Measures auto-router quality independent of placement.

  vacuum-cli check <file.vpcb>
      Run DRC + ratsnest on the top-level board: lists every DRC issue and
      every still-unrouted net. Top-level only (subparts aren't descended into;
      open a subpart's own file to check it). Validates physical connectivity
      headlessly.

  vacuum-cli continuity <file.vpcb> [--flatten] [--probe NET] [--json]
      Export a pneumatic continuity ("buzz-out") checklist: for each net, every
      physical opening you can press a vacuum tube against — transistor gate &
      source/drain, port/vent/source edge bores, resistor ends, connector tubes
      and vias — with its layer and board-mm position. Probe one point and every
      point on that net should pull a hard vacuum while nothing on any other net
      moves. Catches the print-vs-design faults the simulator can't (a channel
      that didn't print through, two channels fused, a via that didn't connect).
      Defaults to top-level routes only; pass --flatten to expand every embedded
      subpart's internal holes into board coordinates (the whole printed board,
      labels prefixed e.g. U6.Q1.gate) — use this when the board contains
      subparts. --probe NET limits output to one net by label; repeatable.

  vacuum-cli collisions <file.vpcb> [--json]
      Decompose the (flattened) board into physical volumes and assert no two
      *separate* volumes touch on the same plate — an independent, 3D
      short-check. Because every intended connection (route, same-plate via,
      resistor) is already merged into one volume, an overlap is an unintended
      fusion of two distinct nets. Catches shorts the 2D DRC can miss (inter-
      depth proximity, real bore geometry, flattened subpart channels).

  vacuum-cli mesh <file.vpcb> [--json]
      Build the printed solids (PlateBuilder) and assert each plate is
      watertight, manifold and non-degenerate — i.e. a slicer will accept it.

  vacuum-cli export <file.vpcb> [--out PATH] [--body NAME] [--json]
      Build the printed solids and write them as a single binary STL — the
      same bodies (top plate, bottom plate, stencil, one gasket stencil per
      .bottomExtend connector, mold frame), per-body makeWatertight() and
      merge the GUI's "Save STL" / Bambu path produces.
      Defaults to <file>.stl beside the input. Reports each solid's volume
      and watertightness; exits non-zero (file still written) if any solid is
      not watertight, since a slicer would reject it.
      --body writes ONE solid instead of the whole set — topPlate,
      bottomPlate, stencil, stencil_<connector label> or moldFrame (short
      forms: top, bottom, mold). Useful for printing a single plate as its
      own object.
      --label TEXT unions raised Helvetica text onto the (single) body's upper
      face, centred — so copies that differ only by a swept parameter can still
      be told apart after they leave the bed. --label-size (default 4 mm) and
      --label-emboss (default 0.3 mm) tune it; oversized text is an error.

  vacuum-cli export <file.vpcb> --bambu [--out DIR] [--modifier-xy MM]
                    [--modifier-z MM] [--modifier-voids] [--no-manifest] [--json]
      "Export for Bambu Studio": write one aligned STL pair PER PLATE —
      <base>_top_model.stl + <base>_top_modifier.stl and <base>_bottom_model.stl
      + <base>_bottom_modifier.stl. The models are laid out side by side ON
      THE BED (bottom plate pre-flipped to print orientation); each modifier
      is a print-critical envelope grown around that plate's channels, valve
      chambers, vias and their surrounding walls/roofs/floors, carrying its
      plate's exact layout transform. In Bambu Studio import each pair on its
      own: select the two files, load as one multipart object, switch the
      _modifier part to a Modifier — then repeat for the other pair. The two
      plates stay separate objects, so they can be arranged and printed
      independently (e.g. one plate per job). Never select all four files at
      once (they'd fold into ONE inseparable object) and never "Split
      objects" (splitting detaches the modifier). The stencil / connector
      gasket stencils / mold frame (no pneumatics) are written as separate
      <base>_stencil.stl / <base>_stencil_<label>.stl / <base>_mold.stl
      objects when present.
      Also writes <base>_bambu_export.json (unless --no-manifest). --out is
      the destination directory (default: a <base>_bambu folder beside the
      input). --modifier-xy / --modifier-z override the wall / roof-floor
      margins in mm (default: the document's own modifierMarginXY/Z — the
      values the GUI's envelope slider / Manufacturing settings edit; files
      from before that field default to 1.0 / 0.6).
      --modifier-voids INVERTS the modifier: it claims everything that is NOT
      pneumatic envelope / screw clamp zone / connector footprint, so the
      global (airtight) preset governs the important regions and the modifier
      only downgrades the filler (assign it low sparse infill in Bambu).

  vacuum-cli sweep <file.vpcb> [--max-combos N] [--param ...] [--json]
      Drive every 0/1 combination of the inputs, solve each to convergence,
      assert they all settle (catches oscillation / metastability), and print
      the truth table. Exhaustive: 2^(#inputs) runs.

  vacuum-cli margins <file.vpcb> [--tol F] [--param ...] [--json]
      Re-run the exhaustive sweep across ±tol parameter corners (default ±20%)
      and assert no probe's logic level flips and everything still converges —
      the "works across manufacturing/material variation" guarantee.

  vacuum-cli staleness <file.vpcb> [--lib DIR] [--json]
      Assert the design is self-contained (every subpart pinned to an embedded
      snapshot). With --lib, also flag subparts whose embedded snapshot is
      stale versus the on-disk library file.

  vacuum-cli verify <file.vpcb> [--lib DIR] [--tol F] [--json]
      Run the whole battery (connectivity, staleness, mesh, sweep, margins)
      and exit non-zero unless every gate passes.

SIMULATE OPTIONS:
  --steps N            Number of fixed solver steps (default 500).
  --set LABEL=VALUE     Drive an input. VALUE is vac/atm or a number 0…1.
                        Repeatable.
  --probe LABEL         Only report this probe. Repeatable.
  --all-nets            Also print every net's pressure.
  --phase "SETS[@CAP]"  Run a *stateful* sequence, carrying latch/register
                        state forward between phases (use this to validate
                        memory: write in one phase, read it back in a later
                        one). SETS is comma-separated LABEL=VALUE; drives are
                        sticky (unnamed inputs hold). Each phase runs until it
                        settles or hits CAP steps (default 100000). Repeatable;
                        phases run in order. Overrides --set.
                        e.g. --phase "READ=vac,B0=vac,B1=vac,B2=vac,B3=vac"
                             --phase "READ=atm,B0=atm,B1=atm,B2=atm,B3=atm"
                             --phase "WRITE=vac"
  --epsilon N           Settle threshold (default 1e-5): largest per-net
                        movement across a 100-step window (one sim-second).
  --param NAME=VALUE    Override a simulation parameter. Repeatable. Names:
                        resistance, flow, pumpMax, onConductance,
                        offConductance, gateThreshold, gateHysteresis,
                        capacitance, busDrive, droop, leak, channelR,
                        internalLeak, dt.
                        e.g. --param pumpMax=0.3 --param channelR=0.004
  --json                Machine-readable output.

MINIMIZE OPTIONS:
  --out PATH            Write the minimized board to PATH (.vpcb).
  --seconds N           Wall-clock budget per restart (default 10).
  --restarts N          Independent search restarts, run in parallel across
                        cores; the smallest DRC-clean result wins (default 1).
                        Wall time ≈ --seconds regardless of N (up to core count).
  --seed N              Base PRNG seed (default 0); restart k uses seed+k.
  --iters N             Cap on placement-search trials per restart (default auto).
  --no-orientation      Skip the transistor-orientation pre-pass (which flips
                        transistors to reduce silicone-crossing vias).
  --json                Machine-readable output.

VALIDATION OPTIONS (sweep / margins / staleness / verify):
  --max-combos N        Cap on exhaustive input combinations (default 4096).
                        Raise to brute-force a design with many inputs.
  --tol F               Margin fraction for `margins`/`verify` (default 0.2).
  --lib DIR             Parts folder, for `staleness`/`verify` drift checks.
  --hold LABEL=VALUE    Pin an input (vac/atm) instead of sweeping it, for
                        `sweep`/`margins`/`verify`. Repeatable. Use it to hold a
                        power rail, e.g. --hold J1.VAC=vac, so the sweep doesn't
                        toggle the supply off (a non-operational state).
"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    print(usage)
    exit(0)
}
args.removeFirst()

if command == "-h" || command == "--help" || command == "help" {
    print(usage)
    exit(0)
}

// Pull the positional file path (first arg not starting with "-").
guard let pathIndex = args.firstIndex(where: { !$0.hasPrefix("-") }) else {
    fail("error: missing <file.vpcb>\n\n\(usage)")
}
let path = args.remove(at: pathIndex)

// Flags / options.
var steps = 500
var sets: [(label: String, value: Double)] = []
var probeFilter: [String] = []
var showAllNets = false
var json = false
var outPath: String?
var seconds: Double = 10
var seed: UInt64 = 0
var iters: Int?
var restarts = 1
var optimizeOrientation = true
var phaseArgs: [String] = []
var epsilon = 1e-5
var params = SimulationParameters.defaults
var libDir: String?
var tol = 0.2
var maxCombos = 4096
var holds: [String: Double] = [:]
var flattenFull = false
var volumesMode = false
var bambu = false
var bodySelector: String?
var labelText: String?
var labelSize = 4.0
var labelEmboss = 0.3
var writeManifest = true
// nil = not overridden on the command line; the export then uses the
// document's own manufacturing.modifierMarginXY/Z (what the GUI slider set).
var modifierXYOverride: Double?
var modifierZOverride: Double?
var modifierStyle = BambuExport.ModifierStyle.pneumatics

var i = 0
while i < args.count {
    let arg = args[i]
    switch arg {
    case "--json": json = true
    case "--all-nets": showAllNets = true
    case "--flatten", "--full": flattenFull = true
    case "--volumes": volumesMode = true
    case "--bambu": bambu = true
    case "--no-manifest": writeManifest = false
    case "--modifier-voids": modifierStyle = .voids
    case "--modifier-xy":
        i += 1
        guard i < args.count, let v = Double(args[i]), v >= 0 else { fail("error: --modifier-xy needs a non-negative number (mm)") }
        modifierXYOverride = v
    case "--modifier-z":
        i += 1
        guard i < args.count, let v = Double(args[i]), v >= 0 else { fail("error: --modifier-z needs a non-negative number (mm)") }
        modifierZOverride = v
    case "--steps":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("error: --steps needs an integer") }
        steps = n
    case "--set":
        i += 1
        guard i < args.count else { fail("error: --set needs LABEL=VALUE") }
        let parts = args[i].split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = parseDrive(String(parts[1])) else {
            fail("error: --set expects LABEL=VALUE (e.g. --set A=vac)")
        }
        sets.append((String(parts[0]), value))
    case "--probe":
        i += 1
        guard i < args.count else { fail("error: --probe needs a LABEL") }
        probeFilter.append(args[i])
    case "--phase":
        i += 1
        guard i < args.count else { fail("error: --phase needs LABEL=VALUE[,...][@MAXSTEPS]") }
        phaseArgs.append(args[i])
    case "--epsilon":
        i += 1
        guard i < args.count, let v = Double(args[i]), v > 0 else { fail("error: --epsilon needs a positive number") }
        epsilon = v
    case "--param":
        i += 1
        guard i < args.count else { fail("error: --param needs NAME=VALUE") }
        let parts = args[i].split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = Double(parts[1]) else {
            fail("error: --param expects NAME=VALUE (e.g. --param resistance=0.15)")
        }
        applyParamOverride(&params, name: String(parts[0]), value: value)
    case "--out":
        i += 1
        guard i < args.count else { fail("error: --out needs a PATH") }
        outPath = args[i]
    case "--body":
        i += 1
        guard i < args.count else { fail("error: --body needs a NAME (topPlate, bottomPlate, stencil, moldFrame)") }
        bodySelector = args[i]
    case "--label":
        i += 1
        guard i < args.count else { fail("error: --label needs TEXT") }
        labelText = args[i]
    case "--label-size":
        i += 1
        guard i < args.count, let n = Double(args[i]), n > 0 else { fail("error: --label-size needs a positive number (mm)") }
        labelSize = n
    case "--label-emboss":
        i += 1
        guard i < args.count, let n = Double(args[i]), n > 0 else { fail("error: --label-emboss needs a positive number (mm)") }
        labelEmboss = n
    case "--seconds":
        i += 1
        guard i < args.count, let n = Double(args[i]) else { fail("error: --seconds needs a number") }
        seconds = n
    case "--seed":
        i += 1
        guard i < args.count, let n = UInt64(args[i]) else { fail("error: --seed needs an integer") }
        seed = n
    case "--iters":
        i += 1
        guard i < args.count, let n = Int(args[i]) else { fail("error: --iters needs an integer") }
        iters = n
    case "--restarts":
        i += 1
        guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("error: --restarts needs a positive integer") }
        restarts = n
    case "--no-orientation":
        optimizeOrientation = false
    case "--lib":
        i += 1
        guard i < args.count else { fail("error: --lib needs a DIR") }
        libDir = args[i]
    case "--tol":
        i += 1
        guard i < args.count, let v = Double(args[i]), v > 0, v < 1 else { fail("error: --tol needs a fraction in (0,1), e.g. 0.2") }
        tol = v
    case "--max-combos":
        i += 1
        guard i < args.count, let n = Int(args[i]), n >= 1 else { fail("error: --max-combos needs a positive integer") }
        maxCombos = n
    case "--hold":
        i += 1
        guard i < args.count else { fail("error: --hold needs LABEL=VALUE") }
        let parts = args[i].split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let value = parseDrive(String(parts[1])) else {
            fail("error: --hold expects LABEL=vac/atm (e.g. --hold J1.VAC=vac)")
        }
        holds[String(parts[0])] = value
    default:
        fail("error: unknown option \(arg)\n\n\(usage)")
    }
    i += 1
}

// MARK: - Dispatch

do {
    let doc = try loadDocument(path)
    let network = buildNetwork(doc)

    switch command {
    case "inspect":
        reportInspect(network, json: json)

    case "simulate":
        if !phaseArgs.isEmpty {
            // Stateful sequence: carry latch/register state across phases.
            // Default per-phase cap is generous since convergence exits early
            // (the windowed settle test rides slow leak↔pump tails out, so
            // honest settles run longer than the old per-step test did).
            let defaultCap = max(steps, 100_000)
            let phases = phaseArgs.map { parsePhase($0, defaultMaxSteps: defaultCap) }
            let results = simulateSequence(network: network, params: params, phases: phases, epsilon: epsilon)
            reportSequence(network: network, results: results, probeFilter: probeFilter, json: json)
            break
        }
        let (inputMap, unmatched) = resolveInputs(network: network, sets: sets)
        if !unmatched.isEmpty {
            fail("error: no input labelled \(unmatched.map { "'\($0)'" }.joined(separator: ", ")). Run `inspect` to see available labels.")
        }
        let result = simulate(network: network, params: params, inputs: inputMap, steps: steps)
        reportSimulate(
            network: network,
            pressures: result.pressures,
            transistors: result.transistors,
            steps: steps,
            showAllNets: showAllNets,
            probeFilter: probeFilter,
            json: json
        )

    case "flows":
        // Settle first — the budget is only meaningful once transient chamber
        // charging has died down (the report says so if it hasn't).
        let settleCap = max(steps, 100_000)
        let finalPressures: [UUID: Double]
        let finalInputs: [UUID: Double]
        let converged: Bool
        let settleSteps: Int
        if !phaseArgs.isEmpty {
            let phases = phaseArgs.map { parsePhase($0, defaultMaxSteps: settleCap) }
            let results = simulateSequence(network: network, params: params,
                                           phases: phases, epsilon: epsilon)
            guard let last = results.last else { fail("error: --phase produced no results") }
            // Rebuild the cumulative (sticky) drive map the sequence ended on,
            // with the same merge rule `simulateSequence` applies.
            var cumulative: [(label: String, value: Double)] = []
            for phase in phases {
                for s in phase.sets {
                    if let j = cumulative.firstIndex(where: { $0.label.lowercased() == s.label.lowercased() }) {
                        cumulative[j] = s
                    } else {
                        cumulative.append(s)
                    }
                }
            }
            finalInputs = resolveInputs(network: network, sets: cumulative).map
            finalPressures = last.pressures
            converged = last.converged
            settleSteps = last.steps
        } else {
            let (inputMap, unmatched) = resolveInputs(network: network, sets: sets)
            if !unmatched.isEmpty {
                fail("error: no input labelled \(unmatched.map { "'\($0)'" }.joined(separator: ", ")). Run `inspect` to see available labels.")
            }
            let r = Validators.simulateToSettle(network: network, params: params,
                                                inputs: inputMap, maxSteps: settleCap,
                                                epsilon: epsilon)
            finalPressures = r.pressures
            finalInputs = inputMap
            converged = r.converged
            settleSteps = r.steps
        }
        let flowReport = FlowAnalysis.report(network: network, params: params,
                                             pressures: finalPressures, inputs: finalInputs)
        reportFlows(flowReport, steps: settleSteps, converged: converged,
                    showEdges: showAllNets, network: network, json: json)

    case "minimize":
        let auto = Minimizer.Options.make(forComponentCount: doc.physical.placements.count)
        func optionsFor(seed s: UInt64) -> Minimizer.Options {
            Minimizer.Options(
                maxIterations: iters ?? auto.maxIterations,
                timeBudget: seconds, seed: s, margin: auto.margin,
                optimizeOrientation: optimizeOrientation
            )
        }
        let (result, stats) = runMinimize(doc, restarts: restarts, baseSeed: seed,
                                           options: optionsFor, verbose: !json)
        reportMinimize(doc, result, stats: stats, json: json)
        if let outPath {
            try result.encoded().write(to: URL(fileURLWithPath: outPath))
            if !json { print("wrote \(outPath)") }
        }

    case "reroute":
        let result = rerouteFromScratch(doc)
        reportReroute(doc, result, json: json)
        if let outPath {
            try result.encoded().write(to: URL(fileURLWithPath: outPath))
            if !json { print("wrote \(outPath)") }
        }

    case "continuity":
        // --flatten expands every embedded subpart's internals into board
        // coordinates (the simulator's netlist-preserving flatten), so the
        // checklist covers the *whole printed board*, not just the open
        // file's own routes. Without it, only top-level routes are listed
        // (same scope as `check`).
        if volumesMode {
            // Volumes are physical, so always work on the whole printed board
            // (flatten is a no-op when there are no subparts).
            let flat = doc.flattenedForSimulation().document
            reportVolumes(flat, volumes: physicalVolumes(flat), json: json)
            break
        }
        let filter = Set(probeFilter.map { $0.lowercased() })
        let target = flattenFull ? doc.flattenedForSimulation().document : doc
        var nets = continuityChecklist(target)
        if !filter.isEmpty { nets = nets.filter { filter.contains($0.net.label.lowercased()) } }
        reportContinuity(target, nets: nets, json: json, flattened: flattenFull)

    case "collisions":
        let r = Validators.volumeCollisions(doc)
        reportCollisions(r, json: json)
        if !r.pass { exit(1) }

    case "check":
        let issues = DRC.check(doc)
        let rats = Ratsnest.missingEdges(doc)
        let errors = issues.filter { $0.severity == .error }
        let warnings = issues.filter { $0.severity == .warning }
        print("DRC issues: \(issues.count) (\(errors.count) error(s), \(warnings.count) warning(s))")
        for issue in errors { print("  ✗ \(issue.summary)") }
        for issue in warnings { print("  ⚠ \(issue.summary)") }
        print("Ratsnest — still-unrouted connections: \(rats.count)")
        for e in rats {
            print(String(format: "  [%@] (%.2f,%.2f) %@ → (%.2f,%.2f) %@",
                         e.netLabel, e.a.x, e.a.y, e.layerA.uiLabel,
                         e.b.x, e.b.y, e.layerB.uiLabel))
        }

    case "mesh":
        let r = Validators.mesh(doc)
        reportMesh(r, json: json)
        if !r.pass { exit(1) }

    case "export":
        if bambu {
            // Per-plate aligned STL pairs (+ optional manifest) for Bambu
            // Studio: each plate's printable model and a print-critical
            // modifier envelope around its channels / valves / vias. Each
            // pair shares one coordinate space, so it loads as one multipart
            // object — and the plates stay two separate objects.
            let base = BambuExport.sanitizedBaseName(path)
            // Document margins are the default; CLI flags override per-axis.
            var modifierMargins = PlateBuilder.ModifierMargins(doc.manufacturing)
            if let v = modifierXYOverride { modifierMargins.xy = v }
            if let v = modifierZOverride { modifierMargins.z = v }
            // --out is the destination directory; default to a <base>_bambu
            // folder next to the source .vpcb.
            let dir = outPath.map { URL(fileURLWithPath: $0) }
                ?? URL(fileURLWithPath: path).deletingLastPathComponent()
                    .appendingPathComponent("\(base)_bambu")
            let r = try BambuExport.writeDirectory(
                doc: doc, baseName: base, directory: dir,
                margins: modifierMargins, style: modifierStyle,
                includeManifest: writeManifest
            )
            reportBambuExport(r, dir: dir, margins: modifierMargins, json: json)
            // Signal unusable geometry (no printable plates, or no pneumatic
            // features to envelope on any plate) while still leaving the
            // files on disk for inspection.
            if r.objects.isEmpty || r.objects.allSatisfy({ $0.modifierMesh == nil }) { exit(1) }
            break
        }
        var bodies = exportBodies(PlateBuilder.build(doc))
        if bodies.isEmpty {
            fail("error: nothing to export — the board produced no printable solids (empty outline?)")
        }
        // --body writes ONE named solid instead of the whole set, so a script can
        // print a single plate without hand-editing the multi-solid STL.
        if let selector = bodySelector {
            let available = bodies.map(\.name)
            // Fixed names resolve through the canonical table; connector
            // gasket stencils (`stencil_<label>`) are matched against the
            // built list case-insensitively.
            let wanted = canonicalBodyName(selector)
                ?? available.first { $0.lowercased() == selector.lowercased() }
            guard let wanted else {
                fail("error: unknown --body \(selector) — expected topPlate, bottomPlate, stencil, "
                     + "a connector gasket stencil (stencil_<label>) or moldFrame")
            }
            bodies = bodies.filter { $0.name == wanted }
            if bodies.isEmpty {
                fail("error: this board has no \(wanted) — it produced \(available.joined(separator: ", "))")
            }
        }
        if let text = labelText {
            guard bodies.count == 1 else {
                fail("error: --label needs a single solid — pass --body too "
                     + "(this board produced \(bodies.map(\.name).joined(separator: ", ")))")
            }
            bodies[0].mesh = embossLabel(on: bodies[0].mesh, text: text,
                                        size: labelSize, emboss: labelEmboss)
        }
        // makeWatertight() stitches the hairline cracks Euclid's BSP CSG leaves
        // where curved surfaces meet flat ones; slicers reject non-manifold STLs,
        // so it runs per body. The bodies are separate printed solids, so we
        // concatenate their polygons into one multi-solid mesh rather than calling
        // Mesh.merge — merge does a boolean CSG union whenever bounds overlap
        // (ours are concentric), which is wasteful and not what a multi-solid STL
        // wants. Mesh(_:) just stores the polygons (no CSG, no BSP).
        let stitched = bodies.map { (name: $0.name, mesh: $0.mesh.makeWatertight()) }
        let data = Mesh(stitched.flatMap { $0.mesh.polygons }).stlData()
        let dest = outPath ?? URL(fileURLWithPath: path)
            .deletingPathExtension().appendingPathExtension("stl").path
        try data.write(to: URL(fileURLWithPath: dest), options: .atomic)
        reportExport(dest: dest, bodies: stitched, bytes: data.count, json: json)
        // Signal scripts that the geometry won't slice cleanly, while still
        // leaving the file on disk for inspection.
        if !stitched.allSatisfy({ bodyPasses($0.mesh) }) { exit(1) }

    case "sweep":
        let settleCap = max(steps, 100_000)
        let sw = Validators.sweep(network: network, params: params,
                                  maxSteps: settleCap, epsilon: epsilon, maxCombos: maxCombos, holds: holds)
        reportSweep(sw, json: json)
        if !sw.allConverged { exit(1) }

    case "margins":
        let settleCap = max(steps, 100_000)
        let prog: (Int, Int, String, Bool, Int) -> Void = { c, total, desc, conv, flips in
            if !json {
                let line = "  corner \(c)/\(total) [\(desc)]: "
                    + (conv ? "" : "non-converging ") + "\(flips) bit-flip(s)\n"
                FileHandle.standardError.write(Data(line.utf8))
            }
        }
        let r = Validators.margins(network: network, base: params, tol: tol,
                                   maxSteps: settleCap, epsilon: epsilon, maxCombos: maxCombos,
                                   holds: holds, progress: prog)
        reportMargins(r, json: json)
        if !r.pass { exit(1) }

    case "staleness":
        let r = Validators.staleness(doc, libDir: libDir)
        reportStaleness(r, libDir: libDir, json: json)
        if !r.pass { exit(1) }

    case "verify":
        // Umbrella: every headless guarantee in one gate. CONNECTIVITY here is
        // top-level only (per `check`); descend into subpart files for a full
        // physical proof. Brute-force by design.
        let settleCap = max(steps, 100_000)
        var allPass = true
        print("── connectivity (DRC + ratsnest, sub-parts flattened) ──")
        let conn = Validators.connectivity(doc)
        print("  DRC errors: \(conn.errors.count), warnings: \(conn.warnings.count), unrouted: \(conn.unrouted)")
        for issue in conn.errors.prefix(40) { print("    ✗ \(issue.summary)") }
        for issue in conn.warnings.prefix(40) { print("    ⚠ \(issue.summary)") }
        allPass = conn.pass && allPass
        print("  \(conn.pass ? (conn.warnings.isEmpty ? "✓ PASS" : "⚠ PASS (with warnings)") : "✗ FAIL")")
        print("── self-containment (staleness) ──")
        let stale = Validators.staleness(doc, libDir: libDir)
        reportStaleness(stale, libDir: libDir, json: false)
        allPass = stale.pass && allPass
        print("── printability (mesh) ──")
        let meshR = Validators.mesh(doc)
        reportMesh(meshR, json: false)
        allPass = meshR.pass && allPass
        print("── logic + convergence (exhaustive sweep) ──")
        let sw = Validators.sweep(network: network, params: params,
                                  maxSteps: settleCap, epsilon: epsilon, maxCombos: maxCombos, holds: holds)
        reportSweep(sw, json: false)
        allPass = sw.allConverged && allPass
        print("── robustness (margins ±\(Int(tol * 100))%) ──")
        let marg = Validators.margins(network: network, base: params, tol: tol,
                                      maxSteps: settleCap, epsilon: epsilon, maxCombos: maxCombos, holds: holds)
        reportMargins(marg, json: false)
        allPass = marg.pass && allPass
        print("── volume collisions (3D short-check, subparts flattened) ──")
        let coll = Validators.volumeCollisions(doc)
        reportCollisions(coll, json: false)
        allPass = coll.pass && allPass
        print("")
        print(allPass ? "VERIFY: ✅ ALL GREEN" : "VERIFY: ❌ FAILED — see above")
        if !allPass { exit(1) }

    default:
        fail("error: unknown command '\(command)'\n\n\(usage)")
    }
} catch {
    fail("error: \(error.localizedDescription)")
}
