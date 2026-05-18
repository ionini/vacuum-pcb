import Foundation

/// Lumped-parameter pneumatic network distilled from a CircuitDocument for
/// interactive simulation.
///
/// One node per net. Components map to edges and boundary conditions:
///   * VAC source pins its net to vacuum (P = 0).
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

    /// Hard boundary: a net forced to a known constant pressure (VAC / ATM).
    /// Inputs are intentionally NOT here — their value depends on user
    /// controls, so the engine reads them from `SimulationState` directly.
    struct HardBoundary {
        let netId: UUID
        let value: Double
    }

    /// A pressure probe surfaced in the Simulate sidebar.
    struct Probe: Identifiable {
        let id: UUID            // component id
        let label: String
        let kind: ComponentKind // .port (output), .led, ...
        let netId: UUID
    }

    /// A user-controllable input. Default pressure is 1 (atmosphere) until the
    /// user toggles it.
    struct Input: Identifiable {
        let id: UUID            // component id
        let label: String
        let netId: UUID
    }

    /// All nets that participate in the simulation, with a stable order so
    /// solver indexing is deterministic across rebuilds.
    let nets: [Net]
    /// Volume-derived capacitance per net id.
    let capacitanceByNet: [UUID: Double]
    let hardBoundaries: [HardBoundary]
    let inputs: [Input]
    let probes: [Probe]
    let transistors: [TransistorEdge]
    let resistors: [ResistorEdge]

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

    static func build(from doc: CircuitDocument) -> PneumaticNetwork {
        let pinToNet = pinToNetMap(doc)

        var hardBoundaries: [HardBoundary] = []
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
                    hardBoundaries.append(HardBoundary(netId: net, value: 0))
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
            }
        }

        let capacitanceByNet = nodeCapacitances(doc: doc)

        return PneumaticNetwork(
            nets: doc.logic.nets,
            capacitanceByNet: capacitanceByNet,
            hardBoundaries: hardBoundaries,
            inputs: inputs,
            probes: probes,
            transistors: transistors,
            resistors: resistors
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
