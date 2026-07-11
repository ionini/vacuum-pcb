import Foundation
import CryptoKit

/// Lumped-parameter pneumatic network distilled from a CircuitDocument for
/// interactive simulation.
///
/// One node per net. Components map to edges and boundary conditions:
///   * VAC source is a soft pump: a conductance edge from its net to a
///     virtual anchor at `pumpMaxVacuum`. Flow capacity and curve shape
///     come from `SimulationParameters` so the user can model a real
///     pump's Q-vs-P curve rather than assuming infinite suction.
///   * ATM vent pins its net to atmosphere (P = 1).
///   * Input port pins its net to the user-controlled pressure for that port.
///   * Output port and LED are read-only probes (no constraint).
///   * Resistor is a fixed-conductance edge between its two pin nets.
///   * Transistor is a variable-conductance edge between its source-and-drain
///     pin nets, gated by its gate-pin net (NMOS-equivalent — opens when the
///     gate sees vacuum, closes when the gate sees atmosphere).
///   * Screws and subparts contribute nothing in v1. Subpart internals are
///     opaque the same way they are to DRC and Ratsnest; the parent file's
///     boundary pins still attach to whatever parent nets touch them.
///
/// Pressure convention is absolute: `0 = full vacuum, 1 = atmosphere`.
struct PneumaticNetwork {
    /// Variable-conductance edge: source↔drain ("a" ↔ "b") of one transistor.
    /// Conductance is a smooth interpolation between off / on driven by the
    /// gate net's pressure (low gate pressure → open, high → closed).
    struct TransistorEdge: Identifiable {
        let id: UUID            // component id
        let label: String
        let gateNet: UUID
        let aNet: UUID
        let bNet: UUID
    }

    /// Fixed-conductance edge: one resistor between its two pin nets.
    struct ResistorEdge: Identifiable {
        let id: UUID            // component id
        let label: String
        let net1: UUID
        let net2: UUID
        /// Effective length of the serpentine path in millimetres. Multiplied
        /// by `SimulationParameters.resistorResistancePerMm` at solve time.
        let pathLengthMm: Double
    }

    /// Weak net↔net edge between two routed channels that run close together
    /// inside one printed plate (a leaky wall). `weight` is a geometric factor
    /// (Σ parallel run length ÷ wall gap over close segment pairs); the solver
    /// multiplies it by `SimulationParameters.internalLeakConductance`.
    struct InterChannelLeak {
        let net1: UUID
        let net2: UUID
        let weight: Double
    }

    /// Hard boundary: a net forced to a known constant pressure (ATM vent).
    /// Inputs are intentionally NOT here — their value depends on user
    /// controls, so the engine reads them from `SimulationState` directly.
    /// Vacuum sources are also not here; they're modelled as soft `Pump`
    /// edges with finite flow capacity.
    struct HardBoundary {
        let netId: UUID
        let value: Double
    }

    /// Soft vacuum source: a conductance edge from `netId` to a virtual
    /// anchor at `SimulationParameters.pumpMaxVacuum`. The effective
    /// conductance depends on the net's current pressure (see
    /// `SimulationParameters.pumpConductance(forNetPressure:)`).
    struct Pump: Identifiable {
        let id: UUID            // component id
        let label: String
        let netId: UUID
    }

    /// A pressure probe surfaced in the Simulate sidebar.
    struct Probe: Identifiable {
        let id: UUID            // component id (or test-point id)
        let label: String
        let kind: ComponentKind // .port (output), .led, ...
        let netId: UUID
        /// True for a testing-point probe — a read-only tap the user placed in
        /// the physical view. Behaviourally identical to an output-port probe
        /// (contributes no boundary/edge); only drives a distinct sidebar icon
        /// and reads its net through the flatten remap (`pressure(rawNet:)`).
        let isTestPoint: Bool

        init(id: UUID, label: String, kind: ComponentKind, netId: UUID,
             isTestPoint: Bool = false) {
            self.id = id
            self.label = label
            self.kind = kind
            self.netId = netId
            self.isTestPoint = isTestPoint
        }
    }

    /// A user-controllable input. Default pressure is 1 (atmosphere) until the
    /// user toggles it.
    struct Input: Identifiable {
        let id: UUID            // component id
        let label: String
        let netId: UUID
        /// When true this is a **soft** drive: it pushes its net toward the
        /// user-selected rail through a *finite* conductance
        /// (`SimulationParameters.busDriveConductance`) and only when the user
        /// asserts a value — a floating selection (`NaN` / absent) contributes
        /// nothing. Bidirectional connector (bus) pins use this so an on-board
        /// tri-state driver can still win the net. A hard input (`false`)
        /// keeps the old behaviour: it clamps its net to atmosphere or joins
        /// the shared vacuum manifold.
        let soft: Bool

        init(id: UUID, label: String, netId: UUID, soft: Bool = false) {
            self.id = id
            self.label = label
            self.netId = netId
            self.soft = soft
        }
    }

    /// All nets that participate in the simulation, with a stable order so
    /// solver indexing is deterministic across rebuilds.
    let nets: [Net]
    /// Volume-derived capacitance per net id.
    let capacitanceByNet: [UUID: Double]
    let hardBoundaries: [HardBoundary]
    let pumps: [Pump]
    let inputs: [Input]
    let probes: [Probe]
    let transistors: [TransistorEdge]
    let resistors: [ResistorEdge]
    /// Channel-to-channel leak paths (see `InterChannelLeak`), computed from the
    /// routed layout; scaled by `SimulationParameters.internalLeakConductance`.
    let interChannelLeaks: [InterChannelLeak]

    /// Deterministic per-pin UUID for a connector pin. The SimulationState
    /// reuses Input/Probe ids as the key in its toggle-state dictionary —
    /// the same connector pin must hash to the same UUID across rebuilds
    /// or the user's input toggles get discarded on every edit. SHA-256
    /// of "componentId:pinKey", truncated to 16 bytes with the UUID v4
    /// version + variant bits forced so the result is a valid UUID.
    static func connectorPinSimulationId(componentId: UUID, pinKey: String) -> UUID {
        let str = componentId.uuidString + ":" + pinKey
        let digest = SHA256.hash(data: Data(str.utf8))
        var b = Array(digest.prefix(16))
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// Returns the net id that owns a given PinRef, if any. Pins that don't
    /// appear on any net (dangling) return nil.
    static func pinToNetMap(_ doc: CircuitDocument) -> [PinRef: UUID] {
        var out: [PinRef: UUID] = [:]
        for net in doc.logic.nets {
            for pin in net.pins {
                out[pin] = net.id
            }
        }
        return out
    }

    /// Builds a pneumatic network from a *flattened* document. Callers
    /// must run `CircuitDocument.flattenedForSimulation()` first when
    /// subparts are in play — this function expects every component on the
    /// doc to be a primitive and every net to be valid.
    /// `SimulationState` does the flattening once per document change and
    /// passes the cached result here so we don't re-flatten per frame.
    static func build(from doc: CircuitDocument) -> PneumaticNetwork {
        let pinToNet = pinToNetMap(doc)

        var hardBoundaries: [HardBoundary] = []
        var pumps: [Pump] = []
        var inputs: [Input] = []
        var probes: [Probe] = []
        var transistors: [TransistorEdge] = []
        var resistors: [ResistorEdge] = []

        func netForSinglePin(_ component: Component) -> UUID? {
            pinToNet[PinRef(componentId: component.id, pinKey: "p")]
        }

        for component in doc.logic.components {
            switch component.kind {
            case .vacuumSource:
                if let net = netForSinglePin(component) {
                    pumps.append(Pump(id: component.id, label: component.label, netId: net))
                }
            case .atmVent:
                if let net = netForSinglePin(component) {
                    hardBoundaries.append(HardBoundary(netId: net, value: 1))
                }
            case .port:
                guard let net = netForSinglePin(component) else { break }
                switch component.portDirection {
                case .input:
                    inputs.append(Input(id: component.id, label: component.label, netId: net))
                case .output, .none:
                    probes.append(Probe(id: component.id, label: component.label,
                                        kind: .port, netId: net))
                }
            case .led:
                if let net = netForSinglePin(component) {
                    probes.append(Probe(id: component.id, label: component.label,
                                        kind: .led, netId: net))
                }
            case .transistor:
                let g = pinToNet[PinRef(componentId: component.id, pinKey: "gate")]
                let a = pinToNet[PinRef(componentId: component.id, pinKey: "a")]
                let b = pinToNet[PinRef(componentId: component.id, pinKey: "b")]
                if let g, let a, let b {
                    transistors.append(TransistorEdge(
                        id: component.id, label: component.label,
                        gateNet: g, aNet: a, bNet: b
                    ))
                }
            case .resistor:
                let n1 = pinToNet[PinRef(componentId: component.id, pinKey: "1")]
                let n2 = pinToNet[PinRef(componentId: component.id, pinKey: "2")]
                if let n1, let n2 {
                    let length = serpentineLength(for: component.resistorSize ?? .medium)
                    resistors.append(ResistorEdge(
                        id: component.id, label: component.label,
                        net1: n1, net2: n2,
                        pathLengthMm: length
                    ))
                }
            case .subpart, .screw:
                // No edge contribution in v1. Subpart internals live behind
                // boundary pins (parent nets only); screws are mechanical.
                break
            case .connector:
                // Each connector pin is an external terminal — surfaced to
                // the simulator UI per-pin so the user can drive (or read)
                // each one independently. The electrical behaviour comes from
                // `resolvedConnectorSignal`, *not* the physical role:
                //   .input         → user-driven hard input.
                //   .output        → read-only probe.
                //   .bidirectional → bus terminal: a probe (always readable)
                //                    *and* a soft input (optional finite-
                //                    conductance drive that defaults to
                //                    floating, so on-board drivers can win).
                let n = max(1, component.connectorPinCount ?? 1)
                let signal = component.resolvedConnectorSignal
                for i in 1...n {
                    let key = String(i)
                    guard let net = pinToNet[PinRef(componentId: component.id, pinKey: key)]
                    else { continue }
                    let pinId = connectorPinSimulationId(componentId: component.id, pinKey: key)
                    let pinLabel = "\(component.label).\(component.connectorPinName(key))"
                    switch signal {
                    case .input:
                        inputs.append(Input(id: pinId, label: pinLabel, netId: net))
                    case .output:
                        probes.append(Probe(id: pinId, label: pinLabel,
                                            kind: .port, netId: net))
                    case .bidirectional:
                        probes.append(Probe(id: pinId, label: pinLabel,
                                            kind: .port, netId: net))
                        inputs.append(Input(id: pinId, label: pinLabel,
                                            netId: net, soft: true))
                    }
                }
            }
        }

        // Testing points are read-only probes: they tap a net for a pressure
        // readout but add no boundary/pump/input, so the solve is unchanged.
        // `doc` is flattened here, which preserves `physical.testPoints`; the
        // stored `netId` is this level's (pre-merge) id, resolved for pressure
        // through the flatten remap by `SimulationState.pressure(probe:)`.
        for tp in doc.physical.testPoints {
            probes.append(Probe(id: tp.id, label: tp.name,
                                kind: .port, netId: tp.netId, isTestPoint: true))
        }

        let capacitanceByNet = nodeCapacitances(doc: doc)

        return PneumaticNetwork(
            nets: doc.logic.nets,
            capacitanceByNet: capacitanceByNet,
            hardBoundaries: hardBoundaries,
            pumps: pumps,
            inputs: inputs,
            probes: probes,
            transistors: transistors,
            resistors: resistors,
            interChannelLeaks: InternalLeakGeometry.leaks(in: doc)
        )
    }

    private static func serpentineLength(for size: ResistorSize) -> Double {
        let halfLen = ManufacturingConstants.resistorFootprintLength / 2
        let halfWid = ManufacturingConstants.resistorFootprintWidth / 2
        let transitions = ResistorGeometry.transitions(for: size)
        let pts = ResistorGeometry.path(transitions: transitions,
                                        halfLen: halfLen, halfWid: halfWid)
        return polylineLength(pts)
    }

    private static func polylineLength(_ pts: [Point]) -> Double {
        guard pts.count >= 2 else { return 0 }
        var total = 0.0
        for i in 0..<(pts.count - 1) {
            let dx = pts[i + 1].x - pts[i].x
            let dy = pts[i + 1].y - pts[i].y
            total += (dx * dx + dy * dy).squareRoot()
        }
        return total
    }

    /// Per-net capacitance: a small per-pin baseline plus the volume of any
    /// route segments tagged to that net. Pin cavity volumes (dimples, drop
    /// bores) are folded into the baseline rather than tracked exactly — v1
    /// only needs the integration to be stable across the open/closed
    /// conductance ratio, not to be quantitatively right.
    private static func nodeCapacitances(doc: CircuitDocument) -> [UUID: Double] {
        var out: [UUID: Double] = [:]
        for net in doc.logic.nets {
            let pinCount = Double(net.pins.count)
            out[net.id] = max(0.1, pinCount * SimulationParameters.defaults.nodeBaseCapacitance)
        }
        for route in doc.physical.routes {
            var length = 0.0
            for seg in route.segments {
                for i in 0..<max(0, seg.waypoints.count - 1) {
                    let dx = seg.waypoints[i + 1].position.x - seg.waypoints[i].position.x
                    let dy = seg.waypoints[i + 1].position.y - seg.waypoints[i].position.y
                    length += (dx * dx + dy * dy).squareRoot()
                }
            }
            out[route.netId, default: 0] += length * SimulationParameters.defaults.channelCapacitancePerMm
        }
        return out
    }
}

/// Geometry for channel-to-channel ("internal") leak: which routed channels run
/// close enough — within a single printed plate — to bleed into each other
/// through the wall between them. Same plate only (top = all its depths, bottom
/// = all its depths); opposite plates are separated by the silicone sheet, a
/// different path we don't model here. Two channels leak more the longer they
/// run alongside each other and the thinner the wall (in-plane gap for the same
/// depth, the inter-layer wall for adjacent depths).
enum InternalLeakGeometry {
    private struct Edge { let netId: UUID; let plate: Plate; let depth: Int; let a: Point; let b: Point }

    private struct Pair: Hashable {
        let a: UUID, b: UUID
        init(_ x: UUID, _ y: UUID) {
            if x.uuidString < y.uuidString { a = x; b = y } else { a = y; b = x }
        }
    }

    /// Net↔net leak weights (Σ run-length ÷ wall gap over close, same-plate,
    /// cross-net segment pairs). Final conductance = weight × the param knob.
    static func leaks(in doc: CircuitDocument) -> [PneumaticNetwork.InterChannelLeak] {
        let m = doc.manufacturing
        let depthPitch = m.channelDiameter + m.interLayerWall   // vertical step per depth
        let window = max(m.minChannelSpacing, depthPitch) * 3   // ignore far-apart channels
        let minGap = max(m.minWallThickness, 0.05)              // floor: touching ≠ infinite

        var edges: [Edge] = []
        for route in doc.physical.routes {
            for seg in route.segments {
                let pts = seg.waypoints
                guard pts.count >= 2 else { continue }
                for i in 0..<(pts.count - 1) {
                    let a = pts[i].position, b = pts[i + 1].position
                    if a.x == b.x && a.y == b.y { continue }    // skip via stubs / zero-length
                    edges.append(Edge(netId: route.netId, plate: seg.layer.plate,
                                      depth: seg.layer.depth, a: a, b: b))
                }
            }
        }

        var weights: [Pair: Double] = [:]
        for i in 0..<edges.count {
            for j in (i + 1)..<edges.count {
                let e = edges[i], f = edges[j]
                if e.netId == f.netId { continue }
                if e.plate != f.plate { continue }              // same printed plate only
                let dxy = segmentDistance(e.a, e.b, f.a, f.b)
                let dz = Double(abs(e.depth - f.depth)) * depthPitch
                let gap = (dxy * dxy + dz * dz).squareRoot()
                guard gap < window else { continue }
                let run = min(length(e.a, e.b), length(f.a, f.b))   // ~ parallel overlap
                weights[Pair(e.netId, f.netId), default: 0] += run / max(gap, minGap)
            }
        }
        // Normalise so the strongest leak path = 1.0. `internalLeakConductance`
        // then reads as "conductance of the worst channel-to-channel leak" in
        // solver units (a resistor edge is ≈0.2, transistor-on = 5), giving a
        // playable 0…1 knob. Relative weights still rank which channels leak
        // most, and a board with more near-max neighbours scrambles sooner.
        guard let maxW = weights.values.max(), maxW > 0 else { return [] }
        return weights.map {
            PneumaticNetwork.InterChannelLeak(net1: $0.key.a, net2: $0.key.b,
                                              weight: $0.value / maxW)
        }
    }

    private static func length(_ a: Point, _ b: Point) -> Double {
        ((b.x - a.x) * (b.x - a.x) + (b.y - a.y) * (b.y - a.y)).squareRoot()
    }

    private static func segmentDistance(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Double {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(min(pointSeg(a, c, d), pointSeg(b, c, d)),
                   min(pointSeg(c, a, b), pointSeg(d, a, b)))
    }

    private static func pointSeg(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let lenSq = dx * dx + dy * dy
        guard lenSq > 0 else { return length(p, a) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lenSq))
        return length(p, Point(x: a.x + t * dx, y: a.y + t * dy))
    }

    private static func segmentsIntersect(_ a: Point, _ b: Point, _ c: Point, _ d: Point) -> Bool {
        func ccw(_ p: Point, _ q: Point, _ r: Point) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        return (ccw(a, b, c) > 0) != (ccw(a, b, d) > 0)
            && (ccw(c, d, a) > 0) != (ccw(c, d, b) > 0)
    }
}
