import Foundation

/// Backward-Euler integrator on top of a `PneumaticNetwork`.
///
/// Each tick we build a sparse-but-dense (small N) admittance matrix Y of
/// conductances between free nets, fold the C/dt term into the diagonal, and
/// solve `(Y + C/dt) P_new = (C/dt) P_old + Σ G·P_pinned` for the free nets.
///
/// Transistor conductance depends on the gate net's pressure, which itself
/// changes during the solve. We iterate the conductance evaluation against
/// the previous step's pressures (Gauss-Seidel style); two or three passes
/// converge for the gate switching dynamics we care about. The smoothed
/// sigmoidal ramp around the gate threshold keeps the integrator stable so
/// long state doesn't ping-pong.
enum SimulationEngine {

    /// One time step. `pressures` is mutated in place. `inputs` is a snapshot
    /// of user-set input port pressures keyed by component id.
    static func step(
        network: PneumaticNetwork,
        params: SimulationParameters,
        pressures: inout [UUID: Double],
        inputs: [UUID: Double],
        transistorOpenness: inout [UUID: Double]
    ) {
        // Routed-channel subdivision: when the user gives channels a per-mm
        // resistance, every routed net splits into its `ChannelGraph` nodes
        // and each device attaches at its own bore's vertex. At the default
        // 0 the graph is ignored and the solve is the historical
        // one-node-per-net system, bit-for-bit.
        let graph = network.channelGraph
        let subdivided = params.channelResistancePerMm > 0 && !graph.isEmpty

        // Anchor table: node id → fixed pressure value. ATM vents and any
        // input toggled to atmosphere pin their nodes at 1.0. Inputs toggled
        // to vacuum are *not* anchored — they join the shared pump manifold
        // below, so they share the pump's finite Q-vs-P budget rather than
        // acting as perfect infinite sources.
        var anchored: [UUID: Double] = [:]
        for boundary in network.hardBoundaries {
            anchored[subdivided ? boundary.nodeId : boundary.netId] = boundary.value
        }
        // Only *hard* inputs clamp their node. Soft (bus) inputs are stamped
        // as finite-conductance edges further below so they never pin a net.
        for input in network.inputs where !input.soft {
            if (inputs[input.id] ?? 1.0) >= 0.5 {
                anchored[subdivided ? input.nodeId : input.netId] = 1.0
            }
        }

        // Manifold-tapped nodes: every `vacuumSource` plus every input the
        // user has toggled to Vac. In real hardware these all hang off one
        // physical vacuum line, so they share a single Q-vs-P curve. We
        // tie them together with a stiff conductance below and stamp a
        // single pump edge on a canonical member.
        var manifoldNets = Set<UUID>()
        for pump in network.pumps {
            manifoldNets.insert(subdivided ? pump.nodeId : pump.netId)
        }
        for input in network.inputs where !input.soft && (inputs[input.id] ?? 1.0) < 0.5 {
            manifoldNets.insert(subdivided ? input.nodeId : input.netId)
        }

        // Build free-node index. Pinned nodes get pinned directly in
        // `pressures`; only free nodes become unknowns. Sub-nodes join the
        // system only when subdivision is active.
        var freeIndex: [UUID: Int] = [:]
        var freeIds: [UUID] = []
        let solverNets: [Net] = subdivided ? network.nets + graph.subNodes : network.nets
        for net in solverNets {
            if anchored[net.id] == nil {
                freeIndex[net.id] = freeIds.count
                freeIds.append(net.id)
            }
        }
        // Force anchored nets to their boundary value so the rest of the
        // solver and the UI both read consistent state.
        for (netId, value) in anchored {
            pressures[netId] = value
        }
        guard !freeIds.isEmpty else { return }

        let dt = max(params.dtSeconds, 1e-6)

        let n = freeIds.count
        // One contiguous buffer for the row-major NxN matrix and a parallel
        // RHS / solution vector. Nested-array variants were burning
        // measurable time on per-step allocations at 60 Hz; a single
        // `[Double]` reuses across the two iterations and stresses the
        // allocator only when the network shape actually changes.
        var y = [Double](repeating: 0, count: n * n)
        var rhs = [Double](repeating: 0, count: n)
        var solution = [Double](repeating: 0, count: n)

        // One pass is enough when gate states change slowly. Two gives us a
        // little extra robustness when an input flip causes a cascade.
        for _ in 0..<2 {
            y.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            rhs.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }

            // 1. Capacitance + previous-state RHS.
            for (idx, netId) in freeIds.enumerated() {
                let c = subdivided
                    ? (graph.capacitanceByNode[netId] ?? params.nodeBaseCapacitance)
                    : (network.capacitanceByNet[netId] ?? params.nodeBaseCapacitance)
                let cOverDt = c / dt
                y[idx * n + idx] += cOverDt
                rhs[idx] += cOverDt * (pressures[netId] ?? 1.0)
            }

            // 2. Resistor edges. Conductance = 1 / (length * R_per_mm).
            for r in network.resistors {
                let length = max(0.1, r.pathLengthMm)
                let g = 1.0 / (length * params.resistorResistancePerMm)
                stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                      net1: subdivided ? r.node1 : r.net1,
                      net2: subdivided ? r.node2 : r.net2, g: g)
            }

            // 2b. Channel spans. Only when the user models channel resistance:
            // each routed run between two sub-nodes conducts inversely to its
            // length. Zero-length spans are stiff ties (island bridges, via
            // bores); every span's conductance is capped at the same
            // stiffness the pump manifold uses, so tiny spans and small
            // channelR values can't blow up the matrix conditioning (which
            // shows up as pressures drifting an ulp past the 0…1 range).
            if subdivided {
                let tieG = max(params.transistorOnConductance * 200, 1000)
                for span in graph.spans {
                    let g = span.lengthMm <= 0 ? tieG
                        : min(1.0 / (span.lengthMm * params.channelResistancePerMm), tieG)
                    stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                          net1: span.node1, net2: span.node2, g: g)
                }
            }

            // 3. Shared pump. Every manifold-tapped net (VAC component or
            // vacuum-toggled input) sits on the same physical vacuum line,
            // so they share one Q-vs-P budget. Tie the non-canonical taps
            // to a canonical one with a stiff edge — they collapse to one
            // node in the matrix — then stamp a single pump edge from the
            // canonical net to the virtual `pumpMaxVacuum` anchor.
            let manifoldFreeOrdered: [UUID] = solverNets.compactMap {
                manifoldNets.contains($0.id) && freeIndex[$0.id] != nil ? $0.id : nil
            }
            if let canonical = manifoldFreeOrdered.first {
                // Stiff enough to dominate every other edge in the matrix
                // (resistor G ~ 1, transistor on G = 5) without being so
                // large that pivoting struggles.
                let stiffG = max(params.transistorOnConductance * 200, 1000)
                for netId in manifoldFreeOrdered where netId != canonical {
                    stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                          net1: canonical, net2: netId, g: stiffG)
                }
                let manifoldP = pressures[canonical] ?? 1.0
                let g = params.pumpConductance(forNetPressure: manifoldP)
                if g > 0, let idx = freeIndex[canonical] {
                    y[idx * n + idx] += g
                    rhs[idx] += g * params.pumpMaxVacuum
                }
            }

            // 4. Transistor edges. Conductance depends on gate net pressure
            // (whatever was last solved / anchored).
            for t in network.transistors {
                let gateNode = subdivided ? t.gateNode : t.gateNet
                let gatePressure = anchored[gateNode] ?? pressures[gateNode] ?? 1.0
                let g = params.conductance(forGatePressure: gatePressure)
                transistorOpenness[t.id] = openness(forGatePressure: gatePressure, params: params)
                stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                      net1: subdivided ? t.aNode : t.aNet,
                      net2: subdivided ? t.bNode : t.bNet, g: g)
            }

            // 4b. Soft (bus) input drives. A bidirectional connector pin the
            // user has asserted pulls its net toward a rail through a finite
            // conductance — strong enough to move an idle bus, weak enough
            // that an on-board driver can contend. A floating selection
            // (absent or NaN) drives nothing. The drive target is a virtual
            // anchor (atmosphere = 1.0, or the pump's deadhead for Vac), so
            // we fold it straight into the diagonal + RHS like a free↔anchored
            // edge. If the net is already pinned (some hard boundary owns it)
            // it isn't in `freeIndex` and the soft drive is correctly ignored.
            for input in network.inputs where input.soft {
                guard let raw = inputs[input.id], !raw.isNaN else { continue }
                guard let idx = freeIndex[subdivided ? input.nodeId : input.netId] else { continue }
                let target = raw < 0.5 ? params.pumpMaxVacuum : 1.0
                let g = params.busDriveConductance
                y[idx * n + idx] += g
                rhs[idx] += g * target
            }

            // 4c. Global leak. No real silicone/PCB sandwich seals perfectly,
            // so every free net gets a faint conductive edge to atmosphere
            // (the virtual anchor at 1.0). A net sitting at atm sees no flow;
            // a net the pump is holding at vacuum bleeds back toward atm at a
            // rate proportional to its vacuum depth, exactly like a resistor
            // tied to an ATM vent. The pump's finite Q-vs-P budget then has to
            // keep working to hold the rail down. Skipped entirely at g=0 so
            // a sealed system reproduces the historical behaviour bit-for-bit.
            if params.leakConductance > 0 {
                let g = params.leakConductance
                if subdivided {
                    // A subdivided net carries the same total leak as its
                    // single-node form, split across its nodes in proportion
                    // to each node's share of the net's volume — so turning
                    // channel resistance on doesn't multiply the board's leak.
                    for (idx, nodeId) in freeIds.enumerated() {
                        let share = graph.leakShareByNode[nodeId] ?? 1.0
                        y[idx * n + idx] += g * share
                        rhs[idx] += g * share * 1.0  // atmosphere
                    }
                } else {
                    for idx in 0..<n {
                        y[idx * n + idx] += g
                        rhs[idx] += g * 1.0  // atmosphere
                    }
                }
            }

            // 4d. Channel-to-channel ("internal") leak. Neighbouring channels
            // inside one printed plate bleed into each other through the thin
            // wall between them — a net↔net edge, unlike the net→atm leak
            // above. Each pair's geometric weight (run length ÷ wall gap,
            // precomputed from the layout) is scaled by the user's knob.
            // Skipped at g=0 so a perfectly-printed board is unchanged.
            if params.internalLeakConductance > 0 {
                for leak in network.interChannelLeaks {
                    let g = leak.weight * params.internalLeakConductance
                    stamp(&y, &rhs, n: n, freeIndex: freeIndex, anchored: anchored,
                          net1: leak.net1, net2: leak.net2, g: g)
                }
            }

            // 5. Solve. Dense Gaussian elimination — N is small (number of
            // free nets, typically <30 for hobby designs; channel subdivision
            // grows it by the routed vertex count).
            solve(matrix: &y, rhs: &rhs, n: n, into: &solution)
            for (idx, netId) in freeIds.enumerated() {
                // Physical range is 0…1 (perfect vacuum … atmosphere); every
                // anchor and source lives inside it, so anything outside is
                // elimination round-off. Clamp here so numeric dust never
                // reaches the UI (SwiftUI's ProgressView warns on 1 + 1e-9)
                // or compounds through the C/dt memory term.
                pressures[netId] = min(1.0, max(0.0, solution[idx]))
            }
        }

        // Keep node-addressed readers (test-point probes, port bores) valid
        // when subdivision is off: every sub-node mirrors its hub. Skipped
        // while subdivided — the solve writes real per-node values then.
        if !subdivided {
            for (sub, hub) in graph.hubBySubNode {
                pressures[sub] = pressures[hub] ?? 1.0
            }
        }
    }

    /// Returns a 0…1 "open fraction" suitable for UI rendering. 0 = closed
    /// (gate at atm), 1 = fully open (gate at vacuum).
    private static func openness(forGatePressure p: Double, params: SimulationParameters) -> Double {
        let g = params.conductance(forGatePressure: p)
        let span = params.transistorOnConductance - params.transistorOffConductance
        guard span > 0 else { return 0 }
        return max(0, min(1, (g - params.transistorOffConductance) / span))
    }

    /// Stamps a single conductive edge into the matrix. Two-port version of
    /// the MNA stamp — for a free↔free edge it contributes to both diagonals
    /// and both off-diagonals; for a free↔anchored edge it folds the anchor
    /// value into the RHS instead of growing the matrix.
    ///
    /// The matrix is a row-major flat `[Double]` of length n*n; index it as
    /// `y[row * n + col]`.
    private static func stamp(
        _ y: inout [Double],
        _ rhs: inout [Double],
        n: Int,
        freeIndex: [UUID: Int],
        anchored: [UUID: Double],
        net1: UUID, net2: UUID, g: Double
    ) {
        if net1 == net2 { return }  // self-loop = no-op
        let i = freeIndex[net1]
        let j = freeIndex[net2]
        switch (i, j) {
        case let (ii?, jj?):
            y[ii * n + ii] += g
            y[jj * n + jj] += g
            y[ii * n + jj] -= g
            y[jj * n + ii] -= g
        case let (ii?, nil):
            if let p2 = anchored[net2] {
                y[ii * n + ii] += g
                rhs[ii] += g * p2
            }
        case let (nil, jj?):
            if let p1 = anchored[net1] {
                y[jj * n + jj] += g
                rhs[jj] += g * p1
            }
        case (nil, nil):
            // Both endpoints anchored: edge has no degrees of freedom.
            break
        }
    }

    /// Gaussian elimination with partial pivoting on a row-major flat
    /// matrix. Writes the solution into the caller-provided buffer to
    /// avoid an allocation on every step.
    ///
    /// The loops run on raw buffer pointers: at thousands of solves per
    /// second the checked `Array` subscript's bounds test plus COW
    /// uniqueness probe were the largest single cost in the 2026-07-19
    /// flow-animation trace (~30% of the pegged main thread, all inside
    /// this O(n³) kernel). The arithmetic and its order are unchanged, so
    /// results stay bit-identical to the checked version.
    private static func solve(matrix: inout [Double], rhs: inout [Double], n: Int, into x: inout [Double]) {
        guard n > 0 else { return }
        matrix.withUnsafeMutableBufferPointer { m in
        rhs.withUnsafeMutableBufferPointer { b in
        x.withUnsafeMutableBufferPointer { xb in
            for k in 0..<n {
                let kRow = k * n
                // Partial pivot — find the row with the largest |matrix[r][k]|
                // and swap rows k and maxRow so the pivot is well-conditioned.
                var maxRow = k
                var maxVal = abs(m[kRow + k])
                for r in (k + 1)..<n {
                    let v = abs(m[r * n + k])
                    if v > maxVal { maxVal = v; maxRow = r }
                }
                if maxRow != k {
                    let mRow = maxRow * n
                    for c in 0..<n {
                        let tmp = m[kRow + c]
                        m[kRow + c] = m[mRow + c]
                        m[mRow + c] = tmp
                    }
                    let tmp = b[k]; b[k] = b[maxRow]; b[maxRow] = tmp
                }
                let pivot = m[kRow + k]
                if abs(pivot) < 1e-12 {
                    // Singular column — leave row as-is, treat unknown as previous value.
                    continue
                }
                for r in (k + 1)..<n {
                    let rRow = r * n
                    let factor = m[rRow + k] / pivot
                    if factor == 0 { continue }
                    for c in k..<n {
                        m[rRow + c] -= factor * m[kRow + c]
                    }
                    b[r] -= factor * b[k]
                }
            }
            for k in stride(from: n - 1, through: 0, by: -1) {
                let kRow = k * n
                var sum = b[k]
                for c in (k + 1)..<n {
                    sum -= m[kRow + c] * xb[c]
                }
                let pivot = m[kRow + k]
                xb[k] = abs(pivot) < 1e-12 ? b[k] : sum / pivot
            }
        }
        }
        }
    }
}

// MARK: - Compiled network (Int-indexed step path)
//
// `step(network:...)` above rebuilds its `anchored` / `freeIndex` tables and
// hashes UUID keys on every fixed-`dt` step, even though the tables only
// change when the network is rebuilt or a hard input toggles. The 2026-07-19
// trace put ~12% of engine CPU in Dictionary find/hash/insert. The compiled
// path below freezes those tables once into dense Int-indexed arrays; the
// per-step loop then does zero UUID hashing. Every stamp lands in the same
// order with the same operands as the dictionary path, so the two are
// bit-identical — keep them in lockstep when touching either.

extension SimulationEngine {

    /// A pre-resolved MNA stamp: what `stamp(_:_:n:freeIndex:anchored:...)`
    /// would decide for one edge, frozen into free-slot indices. `j >= 0` is
    /// a free↔free edge between slots `i` and `j`; `j == -1` folds the
    /// anchored endpoint's value into slot `i`'s diagonal + RHS; `i == -1`
    /// is a no-op stamp (kept only where a slot must exist positionally,
    /// e.g. a transistor whose channel edge resolved to nothing). Edges the
    /// dictionary path would ignore — self-loops, both endpoints anchored,
    /// an endpoint that is neither free nor anchored — are dropped at
    /// compile time; they never contributed a stamp.
    struct CompiledStamp {
        var i: Int
        var j: Int
        var anchor: Double
    }

    /// `step`'s per-step network tables, hoisted out of the hot loop and
    /// re-keyed from UUIDs to dense Int indices. Compile once per
    /// (network revision, subdivision flag, hard-input toggle set) — owners
    /// compare those three and recompile when any moves (SimulationState
    /// keys on `networkRevision`; the CLI and validators compile per run /
    /// per phase). Everything here is immutable value data, safe to hop
    /// queues with.
    struct CompiledNetwork {
        // Cache signature.
        /// True when this compile subdivided routed nets into channel-graph
        /// nodes (`params.channelResistancePerMm > 0` and a non-empty graph).
        let subdivided: Bool
        /// Anchor state per hard input in `network.inputs` order (soft
        /// inputs excluded): true = toggled to atmosphere (anchors its
        /// node), false = vacuum (joins the pump manifold). Compare against
        /// `hardInputStates(network:inputs:)` to detect a stale compile.
        let hardInputStates: [Bool]

        // Node tables.
        /// Every solver node in stamping order — `network.nets`, then (when
        /// subdivided) `channelGraph.subNodes`. Position = node index.
        let nodeIds: [UUID]
        /// Nodes `[0..<netCount)` are real nets; the rest are channel
        /// sub-nodes (they only exist in the seed map after the first step —
        /// see `RunState.hadValue`).
        let netCount: Int
        /// Anchored nodes and their pinned pressures; written into the
        /// pressure array at the top of every step, like the dictionary
        /// path's `anchored` writeback.
        let anchorPins: [(node: Int, value: Double)]
        /// Anchored ids that aren't solver nodes (degenerate networks only).
        /// The dictionary path still pinned them into the pressure map, so
        /// `publish` reproduces them.
        let extraAnchorPins: [(id: UUID, value: Double)]
        /// free slot → node index. The free-slot count is the matrix N.
        let freeToNode: [Int]
        var freeCount: Int { freeToNode.count }

        // Per-free-slot data.
        /// free slot → node capacitance; `.nan` means "use
        /// `params.nodeBaseCapacitance` at step time" so live param edits
        /// keep working without a recompile.
        let capacitanceOrNan: [Double]
        /// free slot → the node's share of its net's total leak
        /// (subdivided compiles only; empty otherwise).
        let leakShare: [Double]

        // Edge lists, in exact legacy stamping order.
        let resistorEdges: [(stamp: CompiledStamp, lengthMm: Double)]
        /// Channel spans (subdivided only). `lengthMm` is the raw span
        /// length — the ≤ 0 stiff-tie branch happens at step time.
        let spanEdges: [(stamp: CompiledStamp, lengthMm: Double)]
        /// Stiff manifold ties canonical↔member, in solver-net order.
        let manifoldTies: [CompiledStamp]
        /// Free slot / node index of the canonical manifold net; -1 when
        /// the manifold has no free member.
        let manifoldCanonicalFree: Int
        let manifoldCanonicalNode: Int
        /// Per transistor: where to read the gate (an anchored value wins
        /// over the node pressure; `gateAnchor` is `.nan` when not
        /// anchored, `gateNode` is -1 when the gate id isn't a solver node)
        /// plus the channel edge stamp.
        let transistorEdges: [(gateNode: Int, gateAnchor: Double, stamp: CompiledStamp)]
        /// transistor slot → component id (publish key).
        let transistorIds: [UUID]
        /// Soft (bus) drives that target a free node: index into the
        /// caller's soft-values array + the driven free slot.
        let softDrives: [(softIndex: Int, free: Int)]
        let interLeakEdges: [(stamp: CompiledStamp, weight: Double)]

        // Publish helpers.
        /// Sub-node → hub mirrors for the non-subdivided publish (the
        /// dictionary path mirrored hub pressures into sub-node keys every
        /// step so probe taps stay readable). `hubNode == -1` mirrors
        /// atmosphere, matching `pressures[hub] ?? 1.0`.
        let mirrorPairs: [(sub: UUID, hubNode: Int)]
    }

    /// Mutable integrator state for one `CompiledNetwork`. Arrays are
    /// indexed by the compiled node / transistor slots; convert to the
    /// UUID-keyed dictionaries only at the publish boundary. Scratch
    /// buffers ride along so the hot loop never touches the allocator.
    struct RunState {
        /// node index → pressure.
        var pressures: [Double]
        /// transistor slot → 0…1 open fraction.
        var openness: [Double]
        /// node index → whether the node's id had a value before the last
        /// step. The dictionary convergence check (`prev[netId] ?? value`)
        /// only counts a node's delta once it has a previous value —
        /// sub-nodes and bore anchors appear one step after seeding. All
        /// true from the first step on.
        var hadValue: [Bool]
        /// max |Δ pressure| across the last step, masked by `hadValue` —
        /// the same number the dictionary-diff loop in the validators / CLI
        /// convergence checks computed.
        var lastMaxDelta: Double
        // Solver scratch, reused across steps (the dictionary path
        // allocated the matrix per step).
        fileprivate var y: [Double]
        fileprivate var rhs: [Double]
        fileprivate var solution: [Double]
        fileprivate var prev: [Double]
    }

    /// True when `step` would subdivide routed nets into their channel
    /// graphs for these parameters.
    static func isSubdivided(network: PneumaticNetwork, params: SimulationParameters) -> Bool {
        params.channelResistancePerMm > 0 && !network.channelGraph.isEmpty
    }

    /// Anchor state per hard input (`network.inputs` order, soft skipped):
    /// true = atmosphere. Part of the compile cache key — hard toggles move
    /// nodes between the anchored set and the pump manifold.
    static func hardInputStates(network: PneumaticNetwork, inputs: [UUID: Double]) -> [Bool] {
        var out: [Bool] = []
        out.reserveCapacity(network.inputs.count)
        for input in network.inputs where !input.soft {
            out.append((inputs[input.id] ?? 1.0) >= 0.5)
        }
        return out
    }

    /// Raw drive value per soft input (`network.inputs` order, hard
    /// skipped); an absent entry becomes `.nan` (= floating), matching the
    /// dictionary path's `inputs[input.id]` guard. Recompute whenever the
    /// inputs map changes — this is per-step data, not part of the compile.
    static func softInputValues(network: PneumaticNetwork, inputs: [UUID: Double]) -> [Double] {
        var out: [Double] = []
        for input in network.inputs where input.soft {
            out.append(inputs[input.id] ?? .nan)
        }
        return out
    }

    /// Freeze the network's per-step tables for one anchor configuration.
    /// `hardStates` must come from `hardInputStates(network:inputs:)` for
    /// the same network. Callers must route a compile with
    /// `freeCount == 0` through the legacy dictionary `step` instead — that
    /// path's early-out (pin anchors, touch nothing else) is not worth
    /// mirroring here.
    static func compile(
        network: PneumaticNetwork,
        params: SimulationParameters,
        hardInputStates hardStates: [Bool]
    ) -> CompiledNetwork {
        let graph = network.channelGraph
        let subdivided = isSubdivided(network: network, params: params)

        // Rebuild the anchored / manifold / free tables exactly the way the
        // dictionary step builds them per step (assignment order matters:
        // an atm-toggled input overrides a hard boundary on the same node).
        var anchored: [UUID: Double] = [:]
        for boundary in network.hardBoundaries {
            anchored[subdivided ? boundary.nodeId : boundary.netId] = boundary.value
        }
        var hardIdx = 0
        for input in network.inputs where !input.soft {
            precondition(hardIdx < hardStates.count,
                         "hardInputStates built from a different network")
            if hardStates[hardIdx] {
                anchored[subdivided ? input.nodeId : input.netId] = 1.0
            }
            hardIdx += 1
        }

        var manifoldNets = Set<UUID>()
        for pump in network.pumps {
            manifoldNets.insert(subdivided ? pump.nodeId : pump.netId)
        }
        hardIdx = 0
        for input in network.inputs where !input.soft {
            if !hardStates[hardIdx] {
                manifoldNets.insert(subdivided ? input.nodeId : input.netId)
            }
            hardIdx += 1
        }

        let solverNets: [Net] = subdivided ? network.nets + graph.subNodes : network.nets
        var indexByNode: [UUID: Int] = Dictionary(minimumCapacity: solverNets.count)
        var nodeIds: [UUID] = []
        nodeIds.reserveCapacity(solverNets.count)
        for net in solverNets {
            indexByNode[net.id] = nodeIds.count
            nodeIds.append(net.id)
        }

        // Free-slot assignment mirrors the legacy `freeIndex` loop.
        var freeSlotByNode: [UUID: Int] = Dictionary(minimumCapacity: solverNets.count)
        var freeToNode: [Int] = []
        for net in solverNets where anchored[net.id] == nil {
            freeSlotByNode[net.id] = freeToNode.count
            freeToNode.append(indexByNode[net.id]!)
        }

        var anchorPins: [(node: Int, value: Double)] = []
        var extraAnchorPins: [(id: UUID, value: Double)] = []
        for (id, value) in anchored {
            if let node = indexByNode[id] {
                anchorPins.append((node, value))
            } else {
                extraAnchorPins.append((id, value))
            }
        }

        var capacitanceOrNan: [Double] = []
        var leakShare: [Double] = []
        capacitanceOrNan.reserveCapacity(freeToNode.count)
        for node in freeToNode {
            let id = nodeIds[node]
            let c = subdivided ? graph.capacitanceByNode[id] : network.capacitanceByNet[id]
            capacitanceOrNan.append(c ?? .nan)
        }
        if subdivided {
            leakShare.reserveCapacity(freeToNode.count)
            for node in freeToNode {
                leakShare.append(graph.leakShareByNode[nodeIds[node]] ?? 1.0)
            }
        }

        // The Int twin of `stamp`'s free/anchored case analysis; nil = the
        // dictionary path would not have stamped this edge at all.
        func resolveStamp(_ net1: UUID, _ net2: UUID) -> CompiledStamp? {
            if net1 == net2 { return nil }  // self-loop = no-op
            let i = freeSlotByNode[net1]
            let j = freeSlotByNode[net2]
            switch (i, j) {
            case let (ii?, jj?):
                return CompiledStamp(i: ii, j: jj, anchor: 0)
            case let (ii?, nil):
                guard let p2 = anchored[net2] else { return nil }
                return CompiledStamp(i: ii, j: -1, anchor: p2)
            case let (nil, jj?):
                guard let p1 = anchored[net1] else { return nil }
                return CompiledStamp(i: jj, j: -1, anchor: p1)
            case (nil, nil):
                return nil
            }
        }

        var resistorEdges: [(stamp: CompiledStamp, lengthMm: Double)] = []
        resistorEdges.reserveCapacity(network.resistors.count)
        for r in network.resistors {
            guard let s = resolveStamp(subdivided ? r.node1 : r.net1,
                                       subdivided ? r.node2 : r.net2) else { continue }
            resistorEdges.append((s, max(0.1, r.pathLengthMm)))
        }

        var spanEdges: [(stamp: CompiledStamp, lengthMm: Double)] = []
        if subdivided {
            spanEdges.reserveCapacity(graph.spans.count)
            for span in graph.spans {
                guard let s = resolveStamp(span.node1, span.node2) else { continue }
                spanEdges.append((s, span.lengthMm))
            }
        }

        let manifoldFreeOrdered: [UUID] = solverNets.compactMap {
            manifoldNets.contains($0.id) && freeSlotByNode[$0.id] != nil ? $0.id : nil
        }
        var manifoldTies: [CompiledStamp] = []
        var manifoldCanonicalFree = -1
        var manifoldCanonicalNode = -1
        if let canonical = manifoldFreeOrdered.first {
            manifoldCanonicalFree = freeSlotByNode[canonical]!
            manifoldCanonicalNode = indexByNode[canonical]!
            for netId in manifoldFreeOrdered where netId != canonical {
                if let s = resolveStamp(canonical, netId) {
                    manifoldTies.append(s)
                }
            }
        }

        var transistorEdges: [(gateNode: Int, gateAnchor: Double, stamp: CompiledStamp)] = []
        transistorEdges.reserveCapacity(network.transistors.count)
        for t in network.transistors {
            let gateId = subdivided ? t.gateNode : t.gateNet
            let stamp = resolveStamp(subdivided ? t.aNode : t.aNet,
                                     subdivided ? t.bNode : t.bNet)
                ?? CompiledStamp(i: -1, j: -1, anchor: 0)
            transistorEdges.append((gateNode: indexByNode[gateId] ?? -1,
                                    gateAnchor: anchored[gateId] ?? .nan,
                                    stamp: stamp))
        }

        var softDrives: [(softIndex: Int, free: Int)] = []
        var softIdx = 0
        for input in network.inputs where input.soft {
            if let f = freeSlotByNode[subdivided ? input.nodeId : input.netId] {
                softDrives.append((softIdx, f))
            }
            softIdx += 1
        }

        var interLeakEdges: [(stamp: CompiledStamp, weight: Double)] = []
        interLeakEdges.reserveCapacity(network.interChannelLeaks.count)
        for leak in network.interChannelLeaks {
            guard let s = resolveStamp(leak.net1, leak.net2) else { continue }
            interLeakEdges.append((s, leak.weight))
        }

        var mirrorPairs: [(sub: UUID, hubNode: Int)] = []
        if !subdivided {
            mirrorPairs.reserveCapacity(graph.hubBySubNode.count)
            for (sub, hub) in graph.hubBySubNode {
                mirrorPairs.append((sub, indexByNode[hub] ?? -1))
            }
        }

        return CompiledNetwork(
            subdivided: subdivided,
            hardInputStates: hardStates,
            nodeIds: nodeIds,
            netCount: network.nets.count,
            anchorPins: anchorPins,
            extraAnchorPins: extraAnchorPins,
            freeToNode: freeToNode,
            capacitanceOrNan: capacitanceOrNan,
            leakShare: leakShare,
            resistorEdges: resistorEdges,
            spanEdges: spanEdges,
            manifoldTies: manifoldTies,
            manifoldCanonicalFree: manifoldCanonicalFree,
            manifoldCanonicalNode: manifoldCanonicalNode,
            transistorEdges: transistorEdges,
            transistorIds: network.transistors.map(\.id),
            softDrives: softDrives,
            interLeakEdges: interLeakEdges,
            mirrorPairs: mirrorPairs)
    }

    /// Seed a `RunState` from the UUID-keyed maps (the reverse of
    /// `publish`). Nodes absent from the map start at atmosphere with
    /// `hadValue == false`, exactly like a missing dictionary key.
    static func makeRunState(
        compiled: CompiledNetwork,
        pressures: [UUID: Double],
        transistorOpenness: [UUID: Double]
    ) -> RunState {
        let nodeCount = compiled.nodeIds.count
        var p = [Double](repeating: 1.0, count: nodeCount)
        var had = [Bool](repeating: false, count: nodeCount)
        for i in 0..<nodeCount {
            if let v = pressures[compiled.nodeIds[i]] {
                p[i] = v
                had[i] = true
            }
        }
        var o = [Double](repeating: 0, count: compiled.transistorIds.count)
        for (t, id) in compiled.transistorIds.enumerated() {
            if let v = transistorOpenness[id] { o[t] = v }
        }
        let n = compiled.freeCount
        return RunState(
            pressures: p,
            openness: o,
            hadValue: had,
            lastMaxDelta: 0,
            y: [Double](repeating: 0, count: n * n),
            rhs: [Double](repeating: 0, count: n),
            solution: [Double](repeating: 0, count: n),
            prev: [Double](repeating: 0, count: nodeCount))
    }

    /// Convert a `RunState` back to the UUID-keyed maps the rest of the app
    /// (UI, flow analysis, CLI output) consumes. This is where the
    /// non-subdivided hub→sub mirroring happens — the dictionary path did
    /// it at the end of every step; batching it onto the publish boundary
    /// produces the same keys and values.
    static func publish(
        compiled: CompiledNetwork,
        state: RunState
    ) -> (pressures: [UUID: Double], transistorOpenness: [UUID: Double]) {
        var pressures = [UUID: Double](
            minimumCapacity: compiled.nodeIds.count + compiled.mirrorPairs.count)
        for (i, id) in compiled.nodeIds.enumerated() {
            pressures[id] = state.pressures[i]
        }
        for pin in compiled.extraAnchorPins {
            pressures[pin.id] = pin.value
        }
        for pair in compiled.mirrorPairs {
            pressures[pair.sub] = pair.hubNode >= 0 ? state.pressures[pair.hubNode] : 1.0
        }
        var openness = [UUID: Double](minimumCapacity: compiled.transistorIds.count)
        for (t, id) in compiled.transistorIds.enumerated() {
            openness[id] = state.openness[t]
        }
        return (pressures, openness)
    }

    /// One time step on a compiled network — the Int-indexed twin of
    /// `step(network:params:pressures:inputs:transistorOpenness:)`. Stamps
    /// land in the same order with the same operands, so the two paths stay
    /// bit-identical. `softInputValues` comes from
    /// `softInputValues(network:inputs:)` against the same network.
    /// Requires `compiled.freeCount > 0`.
    static func step(
        compiled: CompiledNetwork,
        params: SimulationParameters,
        state: inout RunState,
        softInputValues: [Double]
    ) {
        let n = compiled.freeCount
        guard n > 0 else { return }
        let nodeCount = compiled.nodeIds.count
        let dt = max(params.dtSeconds, 1e-6)

        // Convergence baseline — the dictionary path's callers diffed the
        // whole pressure map around each step.
        state.prev.withUnsafeMutableBufferPointer { prev in
            state.pressures.withUnsafeBufferPointer { cur in
                prev.baseAddress!.update(from: cur.baseAddress!, count: nodeCount)
            }
        }
        // Pin anchored nodes, matching the per-step `anchored` writeback
        // (after the baseline: a re-anchored node's jump counts as delta).
        for pin in compiled.anchorPins {
            state.pressures[pin.node] = pin.value
        }

        // Two-port MNA stamp on pre-resolved slots — the Int twin of
        // `stamp`. Same contribution order as the dictionary version.
        func apply(_ s: CompiledStamp, g: Double) {
            if s.j >= 0 {
                state.y[s.i * n + s.i] += g
                state.y[s.j * n + s.j] += g
                state.y[s.i * n + s.j] -= g
                state.y[s.j * n + s.i] -= g
            } else if s.i >= 0 {
                state.y[s.i * n + s.i] += g
                state.rhs[s.i] += g * s.anchor
            }
        }

        for _ in 0..<2 {
            state.y.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
            state.rhs.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }

            // 1. Capacitance + previous-state RHS.
            for f in 0..<n {
                let raw = compiled.capacitanceOrNan[f]
                let c = raw.isNaN ? params.nodeBaseCapacitance : raw
                let cOverDt = c / dt
                state.y[f * n + f] += cOverDt
                state.rhs[f] += cOverDt * state.pressures[compiled.freeToNode[f]]
            }

            // 2. Resistor edges.
            for e in compiled.resistorEdges {
                let g = 1.0 / (e.lengthMm * params.resistorResistancePerMm)
                apply(e.stamp, g: g)
            }

            // 2b. Channel spans (subdivided only).
            if compiled.subdivided {
                let tieG = max(params.transistorOnConductance * 200, 1000)
                for e in compiled.spanEdges {
                    let g = e.lengthMm <= 0 ? tieG
                        : min(1.0 / (e.lengthMm * params.channelResistancePerMm), tieG)
                    apply(e.stamp, g: g)
                }
            }

            // 3. Shared pump manifold.
            if compiled.manifoldCanonicalFree >= 0 {
                let stiffG = max(params.transistorOnConductance * 200, 1000)
                for tie in compiled.manifoldTies {
                    apply(tie, g: stiffG)
                }
                let manifoldP = state.pressures[compiled.manifoldCanonicalNode]
                let g = params.pumpConductance(forNetPressure: manifoldP)
                if g > 0 {
                    let idx = compiled.manifoldCanonicalFree
                    state.y[idx * n + idx] += g
                    state.rhs[idx] += g * params.pumpMaxVacuum
                }
            }

            // 4. Transistor edges (+ openness readout).
            for (t, edge) in compiled.transistorEdges.enumerated() {
                let gatePressure = edge.gateAnchor.isNaN
                    ? (edge.gateNode >= 0 ? state.pressures[edge.gateNode] : 1.0)
                    : edge.gateAnchor
                let g = params.conductance(forGatePressure: gatePressure)
                state.openness[t] = openness(forGatePressure: gatePressure, params: params)
                apply(edge.stamp, g: g)
            }

            // 4b. Soft (bus) input drives.
            for drive in compiled.softDrives {
                let raw = drive.softIndex < softInputValues.count
                    ? softInputValues[drive.softIndex] : .nan
                if raw.isNaN { continue }
                let target = raw < 0.5 ? params.pumpMaxVacuum : 1.0
                let g = params.busDriveConductance
                state.y[drive.free * n + drive.free] += g
                state.rhs[drive.free] += g * target
            }

            // 4c. Global leak.
            if params.leakConductance > 0 {
                let g = params.leakConductance
                if compiled.subdivided {
                    for f in 0..<n {
                        let share = compiled.leakShare[f]
                        state.y[f * n + f] += g * share
                        state.rhs[f] += g * share * 1.0  // atmosphere
                    }
                } else {
                    for f in 0..<n {
                        state.y[f * n + f] += g
                        state.rhs[f] += g * 1.0  // atmosphere
                    }
                }
            }

            // 4d. Channel-to-channel ("internal") leak.
            if params.internalLeakConductance > 0 {
                for e in compiled.interLeakEdges {
                    apply(e.stamp, g: e.weight * params.internalLeakConductance)
                }
            }

            // 5. Solve + clamped writeback.
            solve(matrix: &state.y, rhs: &state.rhs, n: n, into: &state.solution)
            for f in 0..<n {
                state.pressures[compiled.freeToNode[f]] = min(1.0, max(0.0, state.solution[f]))
            }
        }

        // Convergence delta over nodes that had a previous value; then every
        // node has one.
        var maxDelta = 0.0
        for i in 0..<nodeCount where state.hadValue[i] {
            maxDelta = max(maxDelta, abs(state.pressures[i] - state.prev[i]))
        }
        state.lastMaxDelta = maxDelta
        for i in 0..<nodeCount {
            state.hadValue[i] = true
        }
    }
}
