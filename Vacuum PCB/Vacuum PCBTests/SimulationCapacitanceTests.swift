import Testing
import Foundation
@testable import Vacuum_PCB

/// The two capacitance knobs (`nodeBaseCapacitance`, `channelCapacitancePerMm`)
/// set how much air a node holds, i.e. the RC time constant of every
/// transient. They used to be dead at runtime: the network baked its
/// capacitances from `SimulationParameters.defaults` at build time, so a live
/// value (slider, `--param capacitance=…`) never reached the solve — a 1000×
/// change produced bit-identical output. These tests pin the contract that
/// makes the bench capacitance-scale calibration possible: capacitance moves
/// the *rate*, never the settled endpoint.
@MainActor
struct SimulationCapacitanceTests {

    /// VAC —R1— node. One pull-up, no vent, sealed (leak 0), so the node's
    /// endpoint is a pure function of the divider and its approach is a
    /// single RC. `routeLengthMm > 0` gives the node net routed volume so the
    /// per-mm knob has something to scale.
    private func makeDoc(routeLengthMm: Double = 0) -> (doc: CircuitDocument, nodeNet: UUID) {
        var doc = CircuitDocument.blank()
        doc.physical.boardOutline = Rect(origin: .zero, size: Size(width: 200, height: 60))
        let pump = Component(kind: .vacuumSource, label: "P1")
        let r1 = Component(kind: .resistor, label: "R1", resistorSize: .medium)
        doc.logic.components = [pump, r1]
        let rail = Net(label: "rail", pins: [PinRef(componentId: pump.id, pinKey: "p"),
                                             PinRef(componentId: r1.id, pinKey: "1")])
        let node = Net(label: "node", pins: [PinRef(componentId: r1.id, pinKey: "2")])
        doc.logic.nets = [rail, node]
        if routeLengthMm > 0 {
            doc.physical.routes = [Route(netId: node.id, segments: [
                Segment(waypoints: [Waypoint(position: Point(x: 10, y: 30)),
                                    Waypoint(position: Point(x: 10 + routeLengthMm, y: 30))],
                        layer: .top)
            ])]
        }
        return (doc, node.id)
    }

    private func sealed(_ mutate: (inout SimulationParameters) -> Void = { _ in })
    -> SimulationParameters {
        var p = SimulationParameters.defaults
        p.leakConductance = 0
        mutate(&p)
        return p
    }

    /// Settled pressure of `netId`, plus how many steps the node needed to
    /// cover half the distance from atmosphere to that endpoint — a
    /// C-proportional stand-in for the time constant.
    private func transient(
        doc: CircuitDocument, netId: UUID, params: SimulationParameters,
        maxSteps: Int = 2_000_000
    ) throws -> (endpoint: Double, stepsToHalf: Int) {
        let network = Validators.buildNetwork(doc)
        // 1e-10 over the 100-step settle window: three orders tighter than
        // the 1e-6 endpoint comparison below, and reachable within the cap
        // even for the 10×-capacitance runs (a routed net's channel tail is
        // the slow part).
        let settled = Validators.simulateToSettle(network: network, params: params,
                                                  inputs: [:], maxSteps: maxSteps,
                                                  epsilon: 1e-10)
        #expect(settled.converged)
        let endpoint = try #require(settled.pressures[netId])
        #expect(endpoint < 0.99)   // the transient has to actually move

        // Second pass: same run, counting steps to the half-way pressure.
        let half = 1.0 - 0.5 * (1.0 - endpoint)
        let compiled = SimulationEngine.compile(
            network: network, params: params,
            hardInputStates: SimulationEngine.hardInputStates(network: network, inputs: [:]))
        var run = SimulationEngine.makeRunState(
            compiled: compiled,
            pressures: Validators.seedPressures(network: network, params: params, inputs: [:]),
            transistorOpenness: [:])
        let soft = SimulationEngine.softInputValues(network: network, inputs: [:])
        let idx = try #require(compiled.nodeIds.firstIndex(of: netId))
        var steps = 0
        while steps < maxSteps, run.pressures[idx] > half {
            SimulationEngine.step(compiled: compiled, params: params,
                                  state: &run, softInputValues: soft)
            steps += 1
        }
        #expect(steps < maxSteps)
        return (endpoint, steps)
    }

    @Test("nodeBaseCapacitance slows the transient without moving the endpoint")
    func nodeBaseCapacitanceIsLive() throws {
        let (doc, node) = makeDoc()
        let base = try transient(doc: doc, netId: node, params: sealed())
        let heavy = try transient(doc: doc, netId: node, params: sealed {
            $0.nodeBaseCapacitance *= 10
        })

        // Same destination…
        #expect(abs(heavy.endpoint - base.endpoint) < 1e-6)
        // …ten times the air to move, so ~10× the steps to get half way.
        // (Loose bounds: dt quantisation and the pump's P-dependent
        // conductance keep it from being exactly linear.)
        #expect(heavy.stepsToHalf > base.stepsToHalf * 5)
        #expect(heavy.stepsToHalf < base.stepsToHalf * 20)
    }

    @Test("channelCapacitancePerMm slows a routed net without moving the endpoint")
    func channelCapacitanceIsLive() throws {
        // 100 mm of channel on the node net: at the default 0.04/mm that is
        // 4.0 of capacitance against the 0.1 pin baseline, so the per-mm knob
        // dominates the node's RC.
        let (doc, node) = makeDoc(routeLengthMm: 100)
        let base = try transient(doc: doc, netId: node, params: sealed())
        let heavy = try transient(doc: doc, netId: node, params: sealed {
            $0.channelCapacitancePerMm *= 10
        })

        #expect(abs(heavy.endpoint - base.endpoint) < 1e-6)
        #expect(heavy.stepsToHalf > base.stepsToHalf * 5)
        #expect(heavy.stepsToHalf < base.stepsToHalf * 20)
    }

    /// Same board, both engine modes: `channelResistancePerMm == 0` solves one
    /// node per net (`PneumaticNetwork.capacitanceShapeByNet`), the default
    /// 0.006 subdivides into channel nodes (`ChannelGraph`). Both used to bake
    /// the knobs; both must now honour them.
    @Test("Capacitance is live with channel subdivision off as well as on")
    func liveInBothEngineModes() throws {
        let (doc, node) = makeDoc(routeLengthMm: 100)
        for channelR in [0.0, SimulationParameters.defaults.channelResistancePerMm] {
            let base = try transient(doc: doc, netId: node, params: sealed {
                $0.channelResistancePerMm = channelR
            })
            let heavy = try transient(doc: doc, netId: node, params: sealed {
                $0.channelResistancePerMm = channelR
                $0.nodeBaseCapacitance *= 10
                $0.channelCapacitancePerMm *= 10
            })
            #expect(abs(heavy.endpoint - base.endpoint) < 1e-6)
            #expect(heavy.stepsToHalf > base.stepsToHalf * 5)
        }
    }

    /// The shape is the geometry alone — pin count and routed millimetres —
    /// so the parameters can scale it at step time.
    @Test("A net's capacitance shape carries geometry, scaled by the live params")
    func shapeCarriesGeometry() throws {
        let (doc, node) = makeDoc(routeLengthMm: 100)
        let network = Validators.buildNetwork(doc)
        let shape = try #require(network.capacitanceShapeByNet[node])
        #expect(shape.pinUnits == 1)
        #expect(abs(shape.lengthMm - 100) < 1e-9)

        let defaults = SimulationParameters.defaults
        // Historical arithmetic: max(0.1, pins × base) + length × perMm.
        #expect(abs(shape.value(defaults) - (0.1 + 100 * 0.04)) < 1e-12)

        var doubled = defaults
        doubled.channelCapacitancePerMm *= 2
        #expect(abs(shape.value(doubled) - (0.1 + 100 * 0.08)) < 1e-12)
    }
}
