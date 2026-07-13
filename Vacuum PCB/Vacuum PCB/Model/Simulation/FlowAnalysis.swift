import Foundation

/// Post-solve mass-flow readout for one solved pressure map.
///
/// The engine never stores flow — `SimulationEngine.step` stamps each edge's
/// conductance into the admittance matrix and discards it. But every edge is
/// attributable (component id + endpoint nodes) and the solved pressures are
/// published, so Q = G·ΔP is reconstructible after the fact. This is what the
/// Simulate tab's flow overlay, the supply-budget panel and the CLI `flows`
/// report all read.
///
/// The interesting quantity for the supply-starvation work: a pull-up whose
/// load node is vented (its transistor open to atm) passes a *continuous*
/// stream — atm → vent → transistor → pull-up → rail → pump — which is the
/// NMOS-style static draw that sags the rail. A pull-up behind a closed
/// transistor passes only the leak floor once its chamber is evacuated.
///
/// Sign convention: positive edge flow runs node1 → node2 (air moves from
/// high pressure to low). Consumer rows are oriented so positive = air drawn
/// INTO the rail through that path (a load on the pump).
struct FlowReport {
    enum ConsumerKind {
        case resistor       // pull-up / divider leg tied to the rail
        case transistor     // pass valve tied directly to the rail
        case railLeak       // global leak arriving on the rail net itself
        case internalLeak   // channel-to-channel wall leak into the rail
    }

    /// One ranked row of the supply budget: a path air takes into the rail.
    struct Consumer: Identifiable {
        /// Stable row identity for lists (component UUID string, or a fixed
        /// tag for the aggregate leak rows).
        let id: String
        /// Component behind this row; nil for aggregate rows (leak).
        let componentId: UUID?
        let label: String
        /// Load-side context, e.g. the net the pull-up is holding.
        let detail: String
        let kind: ConsumerKind
        /// Air drawn into the rail through this path (solver units·atm/step
        /// scale, same scale as `pumpThroughput`). Positive = load.
        let q: Double
    }

    /// One asserted soft (bus) drive — an *external* line doing supply work
    /// that the on-board pump budget doesn't see. Positive q = the drive is
    /// pulling air out of the board (a Vac assert doing real work).
    struct ExternalDrive: Identifiable {
        let id: UUID
        let label: String
        /// The asserted target, for display ("Vac" / "Atm").
        let towardVacuum: Bool
        let q: Double
    }

    /// True when the solve ran on the subdivided channel graph — per-span
    /// flows in `spanFlows` are real. False = spans carry no information
    /// (every sub-node mirrors its hub) and `spanFlows` is empty.
    let subdivided: Bool
    /// Air the shared pump edge is removing from the board right now.
    let pumpThroughput: Double
    /// The pump's free-flow ceiling: Q with the manifold at atmosphere,
    /// `pumpFlowCapacity × (1 − pumpMaxVacuum)`. Normalizer for utilization.
    let pumpFreeFlowMax: Double
    /// Solved pressure of the canonical manifold node; nil when the board has
    /// no vacuum source (no pump component, no input toggled to Vac).
    let railPressure: Double?
    /// Ranked supply loads, largest first. Sums to `supplyTotal` once the
    /// board settles (transients also charge/discharge chamber volumes).
    let consumers: [Consumer]
    let externalDrives: [ExternalDrive]
    /// Net air the asserted soft drives sitting *on rail nets* are removing —
    /// a bench line feeding the rail through a connector VAC pin does supply
    /// work the pump edge doesn't see (signed; an Atm assert fighting the
    /// rail subtracts).
    let railDriveSupply: Double
    /// Signed through-flow per resistor component id (node1 → node2).
    let flowByResistor: [UUID: Double]
    /// Signed source-drain flow per transistor component id (aNode → bNode).
    let flowByTransistor: [UUID: Double]
    /// Signed flow per channel span, aligned index-for-index with
    /// `PneumaticNetwork.channelGraph.spans`. Empty when not subdivided.
    let spanFlows: [Double]

    /// Fraction of the pump's free-flow ceiling in use, 0…1+.
    var utilization: Double {
        pumpFreeFlowMax > 0 ? pumpThroughput / pumpFreeFlowMax : 0
    }

    /// Everything feeding the rail: the pump edge plus rail-net soft drives.
    /// The number `consumers` should sum to at settle.
    var supplyTotal: Double { pumpThroughput + railDriveSupply }

    static let empty = FlowReport(
        subdivided: false, pumpThroughput: 0, pumpFreeFlowMax: 0,
        railPressure: nil, consumers: [], externalDrives: [],
        railDriveSupply: 0,
        flowByResistor: [:], flowByTransistor: [:], spanFlows: []
    )
}

/// Pure compute over (network, params, solved pressures) — shared by the app
/// (called on each publish tick) and `vacuum-cli flows`. Every conductance
/// formula here mirrors `SimulationEngine.step` stamp-for-stamp; if the
/// engine's stamping changes, this must change with it or the readout lies.
enum FlowAnalysis {

    static func report(
        network: PneumaticNetwork,
        params: SimulationParameters,
        pressures: [UUID: Double],
        inputs: [UUID: Double]
    ) -> FlowReport {
        let graph = network.channelGraph
        let subdivided = params.channelResistancePerMm > 0 && !graph.isEmpty

        func p(_ node: UUID) -> Double { pressures[node] ?? 1.0 }

        // Anchored nodes, exactly as the engine pins them: ATM vents and hard
        // inputs toggled to atmosphere. (Vacuum-toggled inputs are NOT
        // anchored — they join the pump manifold below.)
        var anchored = Set<UUID>()
        for boundary in network.hardBoundaries {
            anchored.insert(subdivided ? boundary.nodeId : boundary.netId)
        }
        for input in network.inputs where !input.soft {
            if (inputs[input.id] ?? 1.0) >= 0.5 {
                anchored.insert(subdivided ? input.nodeId : input.netId)
            }
        }

        // The shared vacuum manifold: every pump barb plus every input the
        // user holds at Vac. Node-level for the canonical pump edge, net-level
        // for boundary attribution (a consumer hangs off the rail *net*, not
        // necessarily the barb's own vertex).
        var manifoldNodes = Set<UUID>()
        var railNets = Set<UUID>()
        for pump in network.pumps {
            manifoldNodes.insert(subdivided ? pump.nodeId : pump.netId)
            railNets.insert(pump.netId)
        }
        for input in network.inputs where !input.soft && (inputs[input.id] ?? 1.0) < 0.5 {
            manifoldNodes.insert(subdivided ? input.nodeId : input.netId)
            railNets.insert(input.netId)
        }

        // Canonical manifold member — first free one in solver order, the node
        // the engine stamps the single pump edge on.
        let solverNets: [Net] = subdivided ? network.nets + graph.subNodes : network.nets
        let canonical = solverNets.first {
            manifoldNodes.contains($0.id) && !anchored.contains($0.id)
        }?.id

        var pumpThroughput = 0.0
        var railPressure: Double?
        if let canonical {
            let manifoldP = p(canonical)
            railPressure = manifoldP
            let g = params.pumpConductance(forNetPressure: manifoldP)
            pumpThroughput = g * (manifoldP - params.pumpMaxVacuum)
        }
        let pumpFreeFlowMax = network.pumps.isEmpty && railNets.isEmpty
            ? 0
            : params.pumpFlowCapacity * (1 - params.pumpMaxVacuum)

        let netLabelById = Dictionary(network.nets.map { ($0.id, $0.label) },
                                      uniquingKeysWith: { a, _ in a })
        func netLabel(_ id: UUID) -> String {
            let label = netLabelById[id] ?? ""
            return label.isEmpty ? String(id.uuidString.prefix(8)) : label
        }

        var consumers: [FlowReport.Consumer] = []
        var flowByResistor: [UUID: Double] = [:]
        var flowByTransistor: [UUID: Double] = [:]

        // Resistor edges. G = 1 / (length × R_per_mm), same floor as the engine.
        for r in network.resistors {
            let g = 1.0 / (max(0.1, r.pathLengthMm) * params.resistorResistancePerMm)
            let q = g * (p(r.node1) - p(r.node2))
            flowByResistor[r.id] = q
            let in1 = railNets.contains(r.net1), in2 = railNets.contains(r.net2)
            guard in1 != in2 else { continue }   // both-in = internal, both-out = mid-path
            let draw = in1 ? -q : q              // positive = air arriving at the rail side
            consumers.append(.init(
                id: r.id.uuidString, componentId: r.id, label: r.label,
                detail: "holds \(netLabel(in1 ? r.net2 : r.net1))",
                kind: .resistor, q: draw
            ))
        }

        // Transistor edges. Gate pressure read the same way the engine does.
        for t in network.transistors {
            let g = params.conductance(forGatePressure: p(t.gateNode))
            let q = g * (p(t.aNode) - p(t.bNode))
            flowByTransistor[t.id] = q
            let inA = railNets.contains(t.aNet), inB = railNets.contains(t.bNet)
            guard inA != inB else { continue }
            let draw = inA ? -q : q
            consumers.append(.init(
                id: t.id.uuidString, componentId: t.id, label: t.label,
                detail: "from \(netLabel(inA ? t.bNet : t.aNet))",
                kind: .transistor, q: draw
            ))
        }

        // Global leak arriving on the rail plumbing itself — pump load that no
        // component owns. Mirrors the engine: free nodes only, volume-shared
        // when subdivided.
        if params.leakConductance > 0, !railNets.isEmpty {
            var q = 0.0
            if subdivided {
                for net in solverNets {
                    let hub = graph.hubBySubNode[net.id] ?? net.id
                    guard railNets.contains(hub), !anchored.contains(net.id) else { continue }
                    let share = graph.leakShareByNode[net.id] ?? 1.0
                    q += params.leakConductance * share * (1.0 - p(net.id))
                }
            } else {
                for netId in railNets where !anchored.contains(netId) {
                    q += params.leakConductance * (1.0 - p(netId))
                }
            }
            if q > 1e-12 {
                consumers.append(.init(
                    id: "rail-leak", componentId: nil, label: "Rail leak",
                    detail: "atm → rail plumbing", kind: .railLeak, q: q
                ))
            }
        }

        // Channel-to-channel wall leak crossing into the rail (net-level edges,
        // exactly as stamped).
        if params.internalLeakConductance > 0 {
            var q = 0.0
            var pairs = 0
            for leak in network.interChannelLeaks {
                let in1 = railNets.contains(leak.net1), in2 = railNets.contains(leak.net2)
                guard in1 != in2 else { continue }
                let g = leak.weight * params.internalLeakConductance
                let rail = in1 ? leak.net1 : leak.net2
                let load = in1 ? leak.net2 : leak.net1
                q += g * (p(load) - p(rail))
                pairs += 1
            }
            if abs(q) > 1e-12 {
                consumers.append(.init(
                    id: "internal-leak", componentId: nil, label: "Wall leak",
                    detail: "\(pairs) channel pair\(pairs == 1 ? "" : "s") → rail",
                    kind: .internalLeak, q: q
                ))
            }
        }

        consumers.sort { $0.q > $1.q }

        // Asserted soft (bus) drives — external supply work, reported apart
        // from the on-board pump budget. Same free-node guard as the engine.
        // A drive sitting on a rail net (a bench line on the connector's VAC
        // pin) is feeding the very rail the consumers draw from, so it also
        // accumulates into `railDriveSupply` for the balance.
        var externalDrives: [FlowReport.ExternalDrive] = []
        var railDriveSupply = 0.0
        for input in network.inputs where input.soft {
            guard let raw = inputs[input.id], !raw.isNaN else { continue }
            let node = subdivided ? input.nodeId : input.netId
            guard !anchored.contains(node) else { continue }
            let towardVacuum = raw < 0.5
            let target = towardVacuum ? params.pumpMaxVacuum : 1.0
            let q = params.busDriveConductance * (p(node) - target)
            externalDrives.append(.init(
                id: input.id, label: input.label, towardVacuum: towardVacuum, q: q
            ))
            if railNets.contains(input.netId) {
                railDriveSupply += q
            }
        }

        // Per-span flows — only meaningful when the solve actually ran on the
        // subdivided graph (otherwise every span's ΔP is zero by construction).
        var spanFlows: [Double] = []
        if subdivided {
            let tieG = max(params.transistorOnConductance * 200, 1000)
            spanFlows.reserveCapacity(graph.spans.count)
            for span in graph.spans {
                let g = span.lengthMm <= 0
                    ? tieG
                    : min(1.0 / (span.lengthMm * params.channelResistancePerMm), tieG)
                spanFlows.append(g * (p(span.node1) - p(span.node2)))
            }
        }

        return FlowReport(
            subdivided: subdivided,
            pumpThroughput: pumpThroughput,
            pumpFreeFlowMax: pumpFreeFlowMax,
            railPressure: railPressure,
            consumers: consumers,
            externalDrives: externalDrives,
            railDriveSupply: railDriveSupply,
            flowByResistor: flowByResistor,
            flowByTransistor: flowByTransistor,
            spanFlows: spanFlows
        )
    }
}
